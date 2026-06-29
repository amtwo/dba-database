CREATE OR ALTER PROCEDURE dbo.Check_StatsDetails
    @DbName              sysname,
    @Mode                varchar(10)   = 'ROLLUP',     -- DETAIL, ROLLUP, or ALL (see header)
    @SchemaName          sysname       = NULL,        -- Filter by schema
    @ObjectName          sysname       = NULL,        -- Filter by table
    @StatisticName       sysname       = NULL,        -- Filter by statistic/index name (DETAIL only)
    @RowCountThreshold   bigint        = 10000000,    -- N rule: >= N rows uses sampled update
    @GiantSamplePercent  tinyint       = 50,          -- Sample percent when table is >= N rows
    @LowSamplePctCutoff  decimal(5,2)  = 5.00,        -- Low sample cutoff for NORECOMPUTE recommendation
    @SkewRatioCutoff     decimal(10,2) = 100.00,      -- Histogram max/avg ratio considered skewed
    @OnlySuspicious      bit           = 0,           -- 1 = only rows that may need action (DETAIL only)
    @IncludeSkewAnalysis bit           = 1,           -- 0 = skip histogram analysis (DETAIL only)
    @Debug               bit           = 0            -- 1 = print dynamic SQL and return
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260629
    Read-only statistics recommendation report for a target database.
    Applies the DB-747 policy model:
    * Tables below @RowCountThreshold => FULLSCAN recommendation
    * Tables at/above @RowCountThreshold => SAMPLE @GiantSamplePercent recommendation
    * Low sample percentages => NORECOMPUTE candidate
    * High histogram skew ratio => filtered statistics review candidate

    @Mode controls the output granularity:
    * DETAIL - One row per statistic, including per-stat sampling and histogram skew.
    * ROLLUP - One row per table, collapsing the per-stat detail to spot tables where
               one stat is under-sampled while its siblings are fine (an index-level
               NORECOMPUTE candidate). This is the default.
    * ALL    - Returns both result sets (DETAIL first, then ROLLUP).

PARAMETERS
* @DbName - Target database name.
* @Mode - Output granularity: DETAIL (per-statistic), ROLLUP (per-table), or ALL (both). Defaults to ROLLUP.
* @SchemaName - Optional schema filter.
* @ObjectName - Optional table filter.
* @StatisticName - Optional statistic/index filter. Only meaningful for DETAIL.
* @RowCountThreshold - Row count breakpoint for sample policy.
* @GiantSamplePercent - Sample percentage for tables at or above the breakpoint.
* @LowSamplePctCutoff - Threshold for low observed sample percentage.
* @SkewRatioCutoff - Threshold for max-step-to-avg-step histogram ratio. Only used by DETAIL.
* @OnlySuspicious - Return only rows with low sample or non-zero modification counter. Only used by DETAIL.
* @IncludeSkewAnalysis - Include histogram analysis (heavier DMV access). Only used by DETAIL.
* @Debug - Print assembled dynamic SQL and exit.

EXAMPLES:
-- Whole database, per-table rollup (the default):
-- EXEC dbo.Check_StatsDetails @DbName = N'Mobo';

-- Per-statistic detail for the whole database:
-- EXEC dbo.Check_StatsDetails @DbName = N'Mobo', @Mode = 'DETAIL';

-- Both result sets at once:
-- EXEC dbo.Check_StatsDetails @DbName = N'Mobo', @Mode = 'ALL';

-- Single table, per-statistic detail:
-- EXEC dbo.Check_StatsDetails
--     @DbName = N'Mobo',
--     @Mode = 'DETAIL',
--     @SchemaName = N'dbo',
--     @ObjectName = N'Order';

-- Single statistic and skip skew analysis:
-- EXEC dbo.Check_StatsDetails
--     @DbName = N'Mobo',
--     @Mode = 'DETAIL',
--     @StatisticName = N'CUIX_OpenOrder',
--     @IncludeSkewAnalysis = 0;

-- Return only suspicious rows:
-- EXEC dbo.Check_StatsDetails
--     @DbName = N'Mobo',
--     @Mode = 'DETAIL',
--     @OnlySuspicious = 1;

-- Print generated SQL only:
-- EXEC dbo.Check_StatsDetails @DbName = N'Mobo', @Debug = 1;

**************************************************************************************************
MODIFICATIONS:
    20260629 - AM2 - Normalize formatting/comments to current repository style.
    20260629 - AM2 - Rename procedure to dbo.Check_StatsDetails to match filename.
    20260629 - AM2 - Add @Mode (DETAIL/ROLLUP/ALL); promote the table-level rollup from an
                     ad-hoc comment into a real, parameterized result set.
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    -- Validate the target database exists before we build anything against it.
    IF DB_ID(@DbName) IS NULL
    BEGIN
        RAISERROR('Database %s not found on this instance.', 16, 1, @DbName);
        RETURN;
    END;

    -- Normalize @Mode so callers don't get tripped up by case or stray whitespace,
    -- then validate it against the supported set before doing any work.
    SET @Mode = UPPER(LTRIM(RTRIM(@Mode)));

    IF @Mode NOT IN ('DETAIL', 'ROLLUP', 'ALL')
    BEGIN
        RAISERROR('@Mode must be one of: DETAIL, ROLLUP, or ALL.', 16, 1);
        RETURN;
    END;

    -- @sql is the batch we ultimately execute. We build the DETAIL and ROLLUP
    -- statements into their own variables, then stitch together whichever ones
    -- the requested @Mode calls for.
    DECLARE
        @sql       nvarchar(max),
        @detailSql nvarchar(max),
        @rollupSql nvarchar(max);

    -- Stats DMVs are database-scoped, so the whole batch must run in the target
    -- database's context. Set it once at the top; every statement we append inherits it.
    SET @sql = N'USE ' + QUOTENAME(@DbName) + N';' + NCHAR(13) + NCHAR(10);

    -------------------------------------------------------------------------------------------
    -- DETAIL: one row per statistic.
    -- TableRows gives us the allocated row count per table (heap or clustered index).
    -- Skew (optional) summarizes histogram step distribution to flag lopsided stats.
    -------------------------------------------------------------------------------------------
    SET @detailSql = N'
    WITH TableRows AS (
        SELECT
            ps.object_id,
            RowCount_Alloc = SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END)
        FROM sys.dm_db_partition_stats AS ps
        GROUP BY ps.object_id
    ),
    Skew AS (
        SELECT
            s.object_id,
            s.stats_id,
            StepCount   = COUNT(*),
            MaxStepRows = MAX(h.equal_rows + h.range_rows),
            AvgStepRows = NULLIF(AVG(h.equal_rows + h.range_rows), 0)
        FROM sys.stats AS s
        CROSS APPLY sys.dm_db_stats_histogram(s.object_id, s.stats_id) AS h
        WHERE @IncludeSkew = 1
        GROUP BY s.object_id, s.stats_id
    )
    SELECT
        DatabaseName   = DB_NAME(),
        SchemaName     = sch.name,
        TableName      = o.name,
        StatName       = s.name,
        RowCount_Alloc = tr.RowCount_Alloc,
        Rows_Stat      = sp.[rows],
        RowsSampled    = sp.rows_sampled,
        SamplePercent  = CONVERT(decimal(5,2), 100.0 * sp.rows_sampled / NULLIF(sp.[rows], 0)),
        ModCounter     = sp.modification_counter,
        ModPct         = TRY_CONVERT(decimal(19,2), 100.0 * sp.modification_counter / NULLIF(sp.[rows], 0)),
        LastUpdated    = sp.last_updated,
        IsNoRecompute  = s.no_recompute,
        IsAutoCreated  = s.auto_created,
        IsUserCreated  = s.user_created,
        IsFiltered     = CASE WHEN s.has_filter = 1 THEN 1 ELSE 0 END,
        -- Skew ratio is max histogram step rows over the average. Only computed when asked.
        SkewRatio      = CASE
                            WHEN @IncludeSkew = 1
                                THEN TRY_CONVERT(decimal(19,2), sk.MaxStepRows / sk.AvgStepRows)
                            ELSE NULL
                         END,
        IsSkewed       = CASE
                            WHEN @IncludeSkew = 1
                                AND (sk.MaxStepRows / sk.AvgStepRows) > @SkewCutoff
                                THEN 1
                            ELSE 0
                         END,
        -- Recommended sample policy: big tables get a sample, everything else FULLSCAN.
        RecSamplePolicy = CASE
                            WHEN tr.RowCount_Alloc >= @N
                                THEN CONCAT(N''SAMPLE '', @GiantPct, N'' PERCENT'')
                            ELSE N''FULLSCAN''
                          END,
        -- Plain-language recommendation, evaluated most-severe-first.
        RecAction = CASE
                        WHEN @IncludeSkew = 1
                             AND (sk.MaxStepRows / sk.AvgStepRows) > @SkewCutoff
                            THEN N''REVIEW: skewed -> consider FILTERED STATISTICS on hot range''
                        WHEN s.auto_created = 1
                             AND CONVERT(decimal(5,2), 100.0 * sp.rows_sampled / NULLIF(sp.[rows], 0)) < @LowCutoff
                            THEN N''NORECOMPUTE candidate (auto-stat under-sampling)''
                        WHEN s.no_recompute = 0
                             AND CONVERT(decimal(5,2), 100.0 * sp.rows_sampled / NULLIF(sp.[rows], 0)) < @LowCutoff
                            THEN N''NORECOMPUTE candidate (low sample, autostats on)''
                        ELSE N''OK / leave as BAU''
                    END,
        -- Copy/paste remediation statement for this specific stat.
        FixSql = CONCAT(
                    N''UPDATE STATISTICS '', QUOTENAME(sch.name), N''.'', QUOTENAME(o.name),
                    N'' ('', QUOTENAME(s.name), N'') WITH '',
                    CASE
                        WHEN tr.RowCount_Alloc >= @N
                            THEN CONCAT(N''SAMPLE '', @GiantPct, N'' PERCENT'')
                        ELSE N''FULLSCAN''
                    END,
                    N'', NORECOMPUTE;'')
    FROM sys.stats AS s
    JOIN sys.objects AS o
        ON o.object_id = s.object_id
    JOIN sys.schemas AS sch
        ON sch.schema_id = o.schema_id
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    LEFT JOIN TableRows AS tr
        ON tr.object_id = s.object_id
    LEFT JOIN Skew AS sk
        ON sk.object_id = s.object_id
        AND sk.stats_id = s.stats_id
    WHERE o.is_ms_shipped = 0
      AND (@SchemaName IS NULL OR sch.name = @SchemaName)
      AND (@ObjectName IS NULL OR o.name = @ObjectName)
      AND (@StatisticName IS NULL OR s.name = @StatisticName)
      AND (
            @OnlySuspicious = 0
            OR CONVERT(decimal(5,2), 100.0 * sp.rows_sampled / NULLIF(sp.[rows], 0)) < @LowCutoff
            OR sp.modification_counter > 0
      )
    ORDER BY
        tr.RowCount_Alloc DESC,
        CONVERT(decimal(5,2), 100.0 * sp.rows_sampled / NULLIF(sp.[rows], 0)) ASC;';

    -------------------------------------------------------------------------------------------
    -- ROLLUP: one row per table.
    -- Collapses the per-stat detail to surface tables where one stat is badly under-sampled
    -- while its siblings look fine -- the classic "fix this one index's stats" scenario.
    -- @StatisticName / @OnlySuspicious / skew don't apply at table grain, so they're ignored here.
    -------------------------------------------------------------------------------------------
    SET @rollupSql = N'
    WITH TableRows AS (
        SELECT
            ps.object_id,
            RowCount_Alloc = SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END)
        FROM sys.dm_db_partition_stats AS ps
        GROUP BY ps.object_id
    ),
    StatDetail AS (
        SELECT
            o.object_id,
            SchemaName    = sch.name,
            TableName     = o.name,
            tr.RowCount_Alloc,
            -- Spread of sample percentages across this table''s stats.
            MinSamplePct  = MIN(CONVERT(decimal(5,2), 100.0 * sp.rows_sampled / NULLIF(sp.[rows], 0))),
            MaxSamplePct  = MAX(CONVERT(decimal(5,2), 100.0 * sp.rows_sampled / NULLIF(sp.[rows], 0))),
            StatCount     = COUNT(*),
            NoRecompute   = SUM(CONVERT(int, s.no_recompute)),
            MaxModCounter = MAX(sp.modification_counter)
        FROM sys.stats AS s
        JOIN sys.objects AS o
            ON o.object_id = s.object_id
        JOIN sys.schemas AS sch
            ON sch.schema_id = o.schema_id
        CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
        LEFT JOIN TableRows AS tr
            ON tr.object_id = s.object_id
        WHERE o.is_ms_shipped = 0
          AND (@SchemaName IS NULL OR sch.name = @SchemaName)
          AND (@ObjectName IS NULL OR o.name = @ObjectName)
        GROUP BY o.object_id, sch.name, o.name, tr.RowCount_Alloc
    )
    SELECT
        SchemaName,
        TableName,
        RowCount_Alloc,
        MinSamplePct,
        MaxSamplePct,
        StatCount,
        NoRecompute,
        MaxModCounter,
        RecSamplePolicy = CASE
                            WHEN RowCount_Alloc >= @N
                                THEN CONCAT(N''SAMPLE '', @GiantPct, N'' PERCENT'')
                            ELSE N''FULLSCAN''
                          END,
        -- Flag tables with a wide sampling spread: at least one stat well under the cutoff
        -- while another is sampled comfortably (>= 20%). That mix points at an index-level fix.
        IndexLevelExceptionFlag = CASE
                                    WHEN MinSamplePct < @LowCutoff
                                         AND MaxSamplePct >= 20.00
                                        THEN N''Mixed: one stat under-sampled while others fine -> consider INDEX-level NORECOMPUTE''
                                    ELSE N''''
                                  END
    FROM StatDetail
    ORDER BY RowCount_Alloc DESC, MinSamplePct ASC;';

    -- Stitch the batch together. DETAIL and ROLLUP both contribute under ALL; each statement
    -- is self-terminated with a semicolon, so they run back-to-back as two result sets.
    IF @Mode IN ('DETAIL', 'ALL')
        SET @sql += @detailSql;

    IF @Mode IN ('ROLLUP', 'ALL')
        SET @sql += @rollupSql;

    -- Debug: dump the assembled SQL and bail. @sql routinely blows past PRINT's 4000-char limit,
    -- so hand it to dbo.Debug_Print, which chunks it on whitespace boundaries for readability.
    IF @Debug = 1
    BEGIN
        EXEC dbo.Debug_Print @DebugMessage = @sql;
        RETURN;
    END;

    -- One unified parameter list serves both statements. ROLLUP simply doesn't reference the
    -- DETAIL-only parameters; passing them anyway is harmless and keeps the call site simple.
    EXEC sys.sp_executesql
        @sql,
        N'@N bigint,
          @GiantPct tinyint,
          @LowCutoff decimal(5,2),
          @SkewCutoff decimal(10,2),
          @OnlySuspicious bit,
          @IncludeSkew bit,
          @SchemaName sysname,
          @ObjectName sysname,
          @StatisticName sysname',
        @N              = @RowCountThreshold,
        @GiantPct       = @GiantSamplePercent,
        @LowCutoff      = @LowSamplePctCutoff,
        @SkewCutoff     = @SkewRatioCutoff,
        @OnlySuspicious = @OnlySuspicious,
        @IncludeSkew    = @IncludeSkewAnalysis,
        @SchemaName     = @SchemaName,
        @ObjectName     = @ObjectName,
        @StatisticName  = @StatisticName;
END;
GO
