CREATE OR ALTER PROCEDURE dbo.Check_StatsDetails
    @DbName              sysname,
    @SchemaName          sysname       = NULL,        -- Filter by schema
    @ObjectName          sysname       = NULL,        -- Filter by table
    @StatisticName       sysname       = NULL,        -- Filter by statistic/index name
    @RowCountThreshold   bigint        = 10000000,    -- N rule: >= N rows uses sampled update
    @GiantSamplePercent  tinyint       = 50,          -- Sample percent when table is >= N rows
    @LowSamplePctCutoff  decimal(5,2)  = 5.00,        -- Low sample cutoff for NORECOMPUTE recommendation
    @SkewRatioCutoff     decimal(10,2) = 100.00,      -- Histogram max/avg ratio considered skewed
    @OnlySuspicious      bit           = 0,           -- 1 = only rows that may need action
    @IncludeSkewAnalysis bit           = 1,           -- 0 = skip histogram analysis
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

PARAMETERS
* @DbName - Target database name.
* @SchemaName - Optional schema filter.
* @ObjectName - Optional table filter.
* @StatisticName - Optional statistic/index filter.
* @RowCountThreshold - Row count breakpoint for sample policy.
* @GiantSamplePercent - Sample percentage for tables at or above the breakpoint.
* @LowSamplePctCutoff - Threshold for low observed sample percentage.
* @SkewRatioCutoff - Threshold for max-step-to-avg-step histogram ratio.
* @OnlySuspicious - Return only rows with low sample or non-zero modification counter.
* @IncludeSkewAnalysis - Include histogram analysis (heavier DMV access).
* @Debug - Print assembled dynamic SQL and exit.

EXAMPLES:
-- Whole database:
-- EXEC dbo.Check_StatsDetails @DbName = N'Mobo';

-- Single table:
-- EXEC dbo.Check_StatsDetails
--     @DbName = N'Mobo',
--     @SchemaName = N'dbo',
--     @ObjectName = N'Order';

-- Single statistic and skip skew analysis:
-- EXEC dbo.Check_StatsDetails
--     @DbName = N'Mobo',
--     @StatisticName = N'CUIX_OpenOrder',
--     @IncludeSkewAnalysis = 0;

-- Return only suspicious rows:
-- EXEC dbo.Check_StatsDetails
--     @DbName = N'Mobo',
--     @OnlySuspicious = 1;

-- Print generated SQL only:
-- EXEC dbo.Check_StatsDetails @DbName = N'Mobo', @Debug = 1;

**************************************************************************************************
MODIFICATIONS:
    20260629 - AM2 - Normalize formatting/comments to current repository style.
    20260629 - AM2 - Rename procedure to dbo.Check_StatsDetails to match filename.
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF DB_ID(@DbName) IS NULL
    BEGIN
        RAISERROR('Database %s not found on this instance.', 16, 1, @DbName);
        RETURN;
    END;

    DECLARE @sql nvarchar(max);

    -- Stats DMVs are database-scoped, so execute in target database context.
    SET @sql = N'
    USE ' + QUOTENAME(@DbName) + N';

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
        RecSamplePolicy = CASE
                            WHEN tr.RowCount_Alloc >= @N
                                THEN CONCAT(N''SAMPLE '', @GiantPct, N'' PERCENT'')
                            ELSE N''FULLSCAN''
                          END,
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

    IF @Debug = 1
    BEGIN
        DECLARE
            @pos int = 1,
            @len int = LEN(@sql),
            @chunk int;

        WHILE @pos <= @len
        BEGIN
            SET @chunk = CHARINDEX(CHAR(10), @sql, @pos + 3500) - @pos;

            IF @chunk <= 0
                SET @chunk = 4000;

            PRINT SUBSTRING(@sql, @pos, @chunk);
            SET @pos = @pos + @chunk;
        END;

        RETURN;
    END;

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

/*
    TABLE-LEVEL ROLLUP (ad-hoc companion query):
    Collapses per-stat rows to one row per table to identify potential
    index-level exception scenarios.

    USE Mobo;

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
        GROUP BY o.object_id, sch.name, o.name, tr.RowCount_Alloc
    )
    SELECT
        *,
        RecSamplePolicy = CASE
                            WHEN RowCount_Alloc >= 10000000 THEN N''SAMPLE 50 PERCENT''
                            ELSE N''FULLSCAN''
                          END,
        IndexLevelExceptionFlag = CASE
                                    WHEN MinSamplePct < 5.00
                                         AND MaxSamplePct >= 20.00
                                        THEN N''Mixed: one stat under-sampled while others fine -> consider INDEX-level NORECOMPUTE''
                                    ELSE N''''
                                  END
    FROM StatDetail
    ORDER BY RowCount_Alloc DESC, MinSamplePct ASC;
*/
