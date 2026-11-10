CREATE OR ALTER PROCEDURE dbo.QueryStore_TextVariantRegressions
    @DatabaseName   sysname,
    @VariantSince   datetimeoffset(7),
    @WindowEnd      datetimeoffset(7) = NULL,
    @BaselineStart  datetimeoffset(7) = NULL,
    @BaselineEnd    datetimeoffset(7) = NULL,
    @MinExecs       bigint            = 20,
    @MinRatio       decimal(9, 2)     = 2.0,
    @MinCpuMs       decimal(9, 2)     = 1.0,
    @NormalizeLineEndings bit         = 1,
    @IgnoreAllWhiteSpace bit          = 1,
    @IgnoreCapitalization bit          = 0,
    @Debug          bit               = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
DESCRIPTION
    Finds regressions among query text variants by normalizing line endings, whitespace, and
    capitalization according to the supplied options. More aggressive normalization can match
    semantically different statements. The report can suggest copying an older variant's hint; it
    never changes Query Store state. Requires Query Store hint support, available in SQL Server
    2022 and later. Ratios compare different time windows, so treat small differences as noise.

PARAMETERS
* @DatabaseName - Target database name. The database must have Query Store enabled.
* @VariantSince - Compile-time cutoff for the new text variants. Required.
* @WindowEnd - End of the new-variant window. Defaults to the current time.
* @BaselineStart - Start of the older-variant baseline window. Defaults to 24 hours before
  @BaselineEnd.
* @BaselineEnd - End of the baseline window. Defaults to @VariantSince.
* @MinExecs - Minimum executions required for a variant. Defaults to 20.
* @MinRatio - Minimum new-variant to baseline CPU-per-execution ratio. Defaults to 2.0.
* @MinCpuMs - Minimum CPU milliseconds per execution for the new variant. Defaults to 1.0.
* @NormalizeLineEndings - Treat CRLF, CR, and LF line endings as equivalent. Defaults to 1.
* @IgnoreAllWhiteSpace - Remove spaces, tabs, and line breaks before matching. Defaults to 1.
* @IgnoreCapitalization - Ignore capitalization when matching. Defaults to 0.
* @Debug - Print the assembled dynamic SQL.

EXAMPLES:
-- Compare new variants since a deployment with the 24 hours before it:
-- EXEC dbo.QueryStore_TextVariantRegressions
--     @DatabaseName = N'AMtwo',
--     @VariantSince = '2026-10-31T09:00:00-04:00';

-- Set explicit windows and a higher regression threshold:
-- EXEC dbo.QueryStore_TextVariantRegressions
--     @DatabaseName = N'AMtwo',
--     @VariantSince = '2026-10-30T09:00:00-04:00',
--     @WindowEnd = '2026-10-31T09:00:00-04:00',
--     @BaselineStart = '2026-10-29T09:00:00-04:00',
--     @BaselineEnd = '2026-10-30T09:00:00-04:00',
--     @MinRatio = 3.0;
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @DatabaseName)
BEGIN
    RAISERROR('Database %s does not exist.', 16, 1, @DatabaseName);
    RETURN;
END;

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @DatabaseName AND is_query_store_on = 1)
BEGIN
    RAISERROR('Database %s does not have Query Store on.', 16, 1, @DatabaseName);
    RETURN;
END;

DECLARE @SupportsQueryStoreHints bit = 0,
        @VersionCheck nvarchar(400) = QUOTENAME(@DatabaseName) + N'.sys.sp_executesql';

EXEC @VersionCheck
    N'SELECT @SupportsQueryStoreHints = CASE WHEN OBJECT_ID(N''sys.query_store_query_hints'') IS NULL THEN 0 ELSE 1 END;',
    N'@SupportsQueryStoreHints bit OUTPUT',
    @SupportsQueryStoreHints = @SupportsQueryStoreHints OUTPUT;

IF @SupportsQueryStoreHints = 0
BEGIN
    RAISERROR('Database %s does not expose Query Store hints. This report requires Query Store hint support, available in SQL Server 2022 and later.', 16, 1, @DatabaseName);
    RETURN;
END;

SET @WindowEnd     = ISNULL(@WindowEnd, SYSDATETIMEOFFSET());
SET @BaselineEnd   = ISNULL(@BaselineEnd, @VariantSince);
SET @BaselineStart = ISNULL(@BaselineStart, DATEADD(HOUR, -24, @BaselineEnd));

DECLARE @Exec nvarchar(400) = QUOTENAME(@DatabaseName) + N'.sys.sp_executesql',
        @UtilityDatabase sysname = DB_NAME(),
        @Sql  nvarchar(max);

SET @Sql = N'
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;

/* Variants that ran in either window, matched by normalized Query Store text. */
CREATE TABLE #Active
(
    query_id                   bigint            NOT NULL PRIMARY KEY,
    query_hash                 binary(8)         NOT NULL,
    object_id                  bigint            NOT NULL,
    initial_compile_start_time datetimeoffset(7) NULL,
    IsNewVariant               bit               NOT NULL,
    QueryTextHash              binary(32)        NOT NULL
);

INSERT #Active (query_id, query_hash, object_id, initial_compile_start_time, IsNewVariant, QueryTextHash)
SELECT
    q.query_id,
    q.query_hash,
    q.object_id,
    q.initial_compile_start_time,
    CASE WHEN q.initial_compile_start_time >= @VariantSince THEN 1 ELSE 0 END,
    CASE WHEN @IgnoreCapitalization = 1
        THEN HASHBYTES(''SHA2_256'', LOWER(wn.NormalizedText COLLATE Latin1_General_100_CI_AS))
        ELSE HASHBYTES(''SHA2_256'', wn.NormalizedText COLLATE Latin1_General_BIN2) END
FROM sys.query_store_query AS q
JOIN sys.query_store_query_text AS qt
    ON qt.query_text_id = q.query_text_id
CROSS APPLY (
    SELECT LineNormalizedText = CASE WHEN @NormalizeLineEndings = 1
        THEN REPLACE(REPLACE(qt.query_sql_text, NCHAR(13) + NCHAR(10), NCHAR(10)), NCHAR(13), NCHAR(10))
        ELSE qt.query_sql_text END
) AS ln
CROSS APPLY (
    SELECT NormalizedText = CASE WHEN @IgnoreAllWhiteSpace = 1
        THEN REPLACE(REPLACE(REPLACE(REPLACE(ln.LineNormalizedText, N'' '', N''''), NCHAR(9), N''''), NCHAR(10), N''''), NCHAR(13), N'''')
        ELSE ln.LineNormalizedText END
) AS wn
WHERE q.last_execution_time >= @BaselineStart;

/* Keep only statements that have both a new variant and an older one. */
DELETE a
FROM #Active AS a
WHERE NOT EXISTS (SELECT 1 FROM #Active AS n WHERE n.QueryTextHash = a.QueryTextHash AND n.IsNewVariant = 1)
   OR NOT EXISTS (SELECT 1 FROM #Active AS o WHERE o.QueryTextHash = a.QueryTextHash AND o.IsNewVariant = 0);

CREATE TABLE #Stats
(
    query_id     bigint     NOT NULL PRIMARY KEY,
    Execs        bigint     NOT NULL,
    CpuUs        float      NOT NULL,
    ReadsTotal   float      NOT NULL,
    RowsTotal    float      NOT NULL
);

INSERT #Stats (query_id, Execs, CpuUs, ReadsTotal, RowsTotal)
SELECT
    a.query_id,
    SUM(rs.count_executions),
    SUM(rs.avg_cpu_time * rs.count_executions),
    SUM(rs.avg_logical_io_reads * rs.count_executions),
    SUM(rs.avg_rowcount * rs.count_executions)
FROM #Active AS a
JOIN sys.query_store_plan AS p
    ON p.query_id = a.query_id
JOIN sys.query_store_runtime_stats AS rs
    ON rs.plan_id = p.plan_id
JOIN sys.query_store_runtime_stats_interval AS rsi
    ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
WHERE (a.IsNewVariant = 1 AND rsi.end_time > @VariantSince  AND rsi.start_time < @WindowEnd)
   OR (a.IsNewVariant = 0 AND rsi.end_time > @BaselineStart AND rsi.start_time < @BaselineEnd)
GROUP BY a.query_id
HAVING SUM(rs.count_executions) >= @MinExecs;

;WITH Baseline AS (
    SELECT
        a.QueryTextHash,
        a.query_id,
        a.query_hash,
        s.Execs,
        CpuMs = s.CpuUs / s.Execs / 1000.0,
        Reads = s.ReadsTotal / s.Execs,
        RowsOut = s.RowsTotal / s.Execs,
        rn    = ROW_NUMBER() OVER (PARTITION BY a.QueryTextHash ORDER BY s.Execs DESC)
    FROM #Active AS a
    JOIN #Stats AS s
        ON s.query_id = a.query_id
    WHERE a.IsNewVariant = 0
)
SELECT
    DatabaseName = DB_NAME(),
    NewQueryId         = n.query_id,
    NewQueryHash       = n.query_hash,
    ObjectName         = OBJECT_SCHEMA_NAME(n.object_id) + N''.'' + OBJECT_NAME(n.object_id),
    NewCompiled        = n.initial_compile_start_time,
    NewExecs           = ns.Execs,
    NewCpuMs           = CONVERT(decimal(18, 2), ns.CpuUs / ns.Execs / 1000.0),
    NewReads           = CONVERT(bigint, ns.ReadsTotal / ns.Execs),
    NewRows            = CONVERT(decimal(18, 1), ns.RowsTotal / ns.Execs),
    BaselineQueryId    = b.query_id,
    BaselineQueryHash  = b.query_hash,
    BaselineExecs      = b.Execs,
    BaselineCpuMs      = CONVERT(decimal(18, 2), b.CpuMs),
    BaselineReads      = CONVERT(bigint, b.Reads),
    BaselineRows       = CONVERT(decimal(18, 1), b.RowsOut),
    CpuRatio           = CONVERT(decimal(18, 2), (ns.CpuUs / ns.Execs / 1000.0) / NULLIF(b.CpuMs, 0)),
    ExcessCpuSec       = CONVERT(decimal(18, 1), ((ns.CpuUs / ns.Execs / 1000.0) - b.CpuMs) * ns.Execs / 1000.0),
    QueryHashChanged   = CASE WHEN n.query_hash <> b.query_hash THEN 1 ELSE 0 END,
    NewHasHint         = CASE WHEN nh.query_id IS NULL THEN 0 ELSE 1 END,
    NewHasForcedPlan   = CASE WHEN EXISTS (SELECT 1 FROM sys.query_store_plan AS fp WHERE fp.query_id = n.query_id AND fp.is_forced_plan = 1) THEN 1 ELSE 0 END,
    BaselineHint       = bh.query_hint_text,
    QuickieStoreCommand = N''EXEC '' + QUOTENAME(@UtilityDatabase) + N''.dbo.sp_QuickieStore @database_name = N'' + NCHAR(39)
        + REPLACE(@DatabaseName, NCHAR(39), NCHAR(39) + NCHAR(39)) + NCHAR(39)
        + N'', @include_query_ids = N'' + NCHAR(39) + CONVERT(nvarchar(20), n.query_id)
        + N'','' + CONVERT(nvarchar(20), b.query_id) + NCHAR(39)
        + N'', @start_date = N'' + NCHAR(39) + CONVERT(nvarchar(35), @BaselineStart, 127) + NCHAR(39)
        + N'', @end_date = N'' + NCHAR(39) + CONVERT(nvarchar(35), @WindowEnd, 127) + NCHAR(39)
        + N'', @expert_mode = 1;'',
    HintSql            = CASE WHEN bh.query_hint_text IS NOT NULL AND nh.query_id IS NULL
                              THEN N''EXEC sys.sp_query_store_set_hints @query_id = '' + CONVERT(nvarchar(20), n.query_id)
                                   + N'', @query_hints = N'''''' + REPLACE(bh.query_hint_text, N'''''''', N'''''''''''') + N'''''';''
                         END,
    RollbackSql        = N''EXEC sys.sp_query_store_clear_hints @query_id = '' + CONVERT(nvarchar(20), n.query_id) + N'';''
FROM #Active AS n
JOIN #Stats AS ns
    ON ns.query_id = n.query_id
JOIN Baseline AS b
    ON b.QueryTextHash = n.QueryTextHash
   AND b.rn = 1
LEFT JOIN sys.query_store_query_hints AS nh
    ON nh.query_id = n.query_id
LEFT JOIN sys.query_store_query_hints AS bh
    ON bh.query_id = b.query_id
WHERE n.IsNewVariant = 1
  AND (ns.CpuUs / ns.Execs / 1000.0) >= @MinCpuMs
  AND (ns.CpuUs / ns.Execs / 1000.0) >= @MinRatio * b.CpuMs
ORDER BY ExcessCpuSec DESC;';

IF @Debug = 1
BEGIN
    PRINT @Sql;
END;

DECLARE @PreviousLockTimeout int = @@LOCK_TIMEOUT;
DECLARE @RestoreLockTimeout nvarchar(50) = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(12), @PreviousLockTimeout);
BEGIN TRY
    EXEC @Exec @Sql,
        N'@DatabaseName sysname, @UtilityDatabase sysname, @VariantSince datetimeoffset(7), @WindowEnd datetimeoffset(7), @BaselineStart datetimeoffset(7), @BaselineEnd datetimeoffset(7), @MinExecs bigint, @MinRatio decimal(9, 2), @MinCpuMs decimal(9, 2), @NormalizeLineEndings bit, @IgnoreAllWhiteSpace bit, @IgnoreCapitalization bit',
        @DatabaseName  = @DatabaseName,
        @UtilityDatabase = @UtilityDatabase,
        @VariantSince  = @VariantSince,
        @WindowEnd     = @WindowEnd,
        @BaselineStart = @BaselineStart,
        @BaselineEnd   = @BaselineEnd,
        @MinExecs      = @MinExecs,
        @MinRatio      = @MinRatio,
        @MinCpuMs      = @MinCpuMs,
        @NormalizeLineEndings = @NormalizeLineEndings,
        @IgnoreAllWhiteSpace = @IgnoreAllWhiteSpace,
        @IgnoreCapitalization = @IgnoreCapitalization;
END TRY
BEGIN CATCH
    EXEC (@RestoreLockTimeout);
    THROW;
END CATCH;
EXEC (@RestoreLockTimeout);
GO
