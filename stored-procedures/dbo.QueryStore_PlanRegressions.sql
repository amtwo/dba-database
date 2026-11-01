CREATE OR ALTER PROCEDURE dbo.QueryStore_PlanRegressions
    @DatabaseName sysname,
    @WindowStart  datetimeoffset(7) = NULL,
    @WindowEnd    datetimeoffset(7) = NULL,
    @MinExecs     bigint            = 50,
    @MinCpuRatio  decimal(9, 2)     = 2.0,
    @Debug        bit               = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
DESCRIPTION
    Compares plans for byte-identical query text within each query_id over the same runtime
    window. It reports a query when the most recently used plan costs at least @MinCpuRatio times
    as much CPU per execution as another plan that meets the execution threshold. Queries with
    only one plan are excluded. The result includes statements to force the lower-CPU plan and
    roll back that change; this procedure is read-only. Requires Query Store hint support, available in SQL Server 2022 and later.

PARAMETERS
* @DatabaseName - Target database name. The database must have Query Store enabled.
* @WindowStart - Start of the runtime-statistics window. Defaults to four hours before @WindowEnd.
* @WindowEnd - End of the runtime-statistics window. Defaults to the current time.
* @MinExecs - Minimum executions required for a plan to be included. Defaults to 50.
* @MinCpuRatio - Minimum latest-plan to best-plan CPU-per-execution ratio. Defaults to 2.0.
* @Debug - Print the assembled dynamic SQL.

EXAMPLES:
-- Find plan regressions in the default four-hour window:
-- EXEC dbo.QueryStore_PlanRegressions @DatabaseName = N'AMtwo';

-- Use a longer window and require at least a 3x CPU regression:
-- EXEC dbo.QueryStore_PlanRegressions
--     @DatabaseName = N'AMtwo',
--     @WindowStart = '2026-10-30T00:00:00-04:00',
--     @WindowEnd = '2026-10-31T00:00:00-04:00',
--     @MinExecs = 100,
--     @MinCpuRatio = 3.0;
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

SET @WindowEnd   = ISNULL(@WindowEnd, SYSDATETIMEOFFSET());
SET @WindowStart = ISNULL(@WindowStart, DATEADD(HOUR, -4, @WindowEnd));

DECLARE @Exec nvarchar(400) = QUOTENAME(@DatabaseName) + N'.sys.sp_executesql',
        @Sql  nvarchar(max);

SET @Sql = N'
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;

DECLARE @MinIntervalId bigint = (
    SELECT MIN(rsi.runtime_stats_interval_id)
    FROM sys.query_store_runtime_stats_interval AS rsi
    WHERE rsi.end_time > @WindowStart
);
DECLARE @MaxIntervalId bigint = (
    SELECT MAX(rsi.runtime_stats_interval_id)
    FROM sys.query_store_runtime_stats_interval AS rsi
    WHERE rsi.start_time < @WindowEnd
);

WITH PlanStats AS (
    SELECT
        q.query_id,
        q.query_hash,
        q.object_id,
        p.plan_id,
        p.query_plan_hash,
        p.is_forced_plan,
        PlanLastExec = MAX(rs.last_execution_time),
        Execs        = SUM(rs.count_executions),
        CpuMsPerExec = SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0,
        DurMsPerExec = SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0,
        ReadsPerExec = SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0),
        RowsPerExec  = SUM(rs.avg_rowcount * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0)
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_plan AS p
        ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query AS q
        ON q.query_id = p.query_id
    WHERE rs.runtime_stats_interval_id BETWEEN @MinIntervalId AND @MaxIntervalId
    GROUP BY q.query_id, q.query_hash, q.object_id, p.plan_id, p.query_plan_hash, p.is_forced_plan
    HAVING SUM(rs.count_executions) >= @MinExecs
),
Ranked AS (
    SELECT
        ps.query_id,
        ps.query_hash,
        ps.object_id,
        ps.plan_id,
        ps.query_plan_hash,
        ps.is_forced_plan,
        ps.Execs,
        ps.CpuMsPerExec,
        ps.DurMsPerExec,
        ps.ReadsPerExec,
        ps.RowsPerExec,
        LatestRn = ROW_NUMBER() OVER (PARTITION BY ps.query_id ORDER BY ps.PlanLastExec DESC),
        BestRn   = ROW_NUMBER() OVER (PARTITION BY ps.query_id ORDER BY ps.CpuMsPerExec ASC)
    FROM PlanStats AS ps
)
SELECT
    l.query_hash,
    l.query_id,
    ObjectName        = OBJECT_SCHEMA_NAME(l.object_id) + N''.'' + OBJECT_NAME(l.object_id),
    LatestPlanId      = l.plan_id,
    LatestPlanHash    = l.query_plan_hash,
    LatestExecs       = l.Execs,
    LatestCpuMs       = CONVERT(decimal(18, 2), l.CpuMsPerExec),
    LatestDurMs       = CONVERT(decimal(18, 2), l.DurMsPerExec),
    LatestReads       = CONVERT(bigint, l.ReadsPerExec),
    LatestRows        = CONVERT(decimal(18, 1), l.RowsPerExec),
    BestPlanId        = b.plan_id,
    BestPlanHash      = b.query_plan_hash,
    BestExecs         = b.Execs,
    BestCpuMs         = CONVERT(decimal(18, 2), b.CpuMsPerExec),
    BestDurMs         = CONVERT(decimal(18, 2), b.DurMsPerExec),
    BestReads         = CONVERT(bigint, b.ReadsPerExec),
    BestRows          = CONVERT(decimal(18, 1), b.RowsPerExec),
    CpuRatio          = CONVERT(decimal(18, 2), l.CpuMsPerExec / NULLIF(b.CpuMsPerExec, 0)),
    ExcessCpuSec      = CONVERT(decimal(18, 1), (l.CpuMsPerExec - b.CpuMsPerExec) * l.Execs / 1000.0),
    AnyPlanForced     = CASE WHEN EXISTS (SELECT 1 FROM sys.query_store_plan AS fp WHERE fp.query_id = l.query_id AND fp.is_forced_plan = 1) THEN 1 ELSE 0 END,
    HintText          = h.query_hint_text,
    ForceSql          = N''EXEC sys.sp_query_store_force_plan @query_id = '' + CONVERT(nvarchar(20), l.query_id)
                        + N'', @plan_id = '' + CONVERT(nvarchar(20), b.plan_id) + N'';'',
    RollbackSql       = N''EXEC sys.sp_query_store_unforce_plan @query_id = '' + CONVERT(nvarchar(20), l.query_id)
                        + N'', @plan_id = '' + CONVERT(nvarchar(20), b.plan_id) + N'';''
FROM Ranked AS l
JOIN Ranked AS b
    ON b.query_id = l.query_id
   AND b.BestRn = 1
LEFT JOIN sys.query_store_query_hints AS h
    ON h.query_id = l.query_id
WHERE l.LatestRn = 1
  AND l.plan_id <> b.plan_id
  AND l.CpuMsPerExec >= @MinCpuRatio * b.CpuMsPerExec
ORDER BY ExcessCpuSec DESC;';

IF @Debug = 1
    PRINT @Sql;

DECLARE @PreviousLockTimeout int = @@LOCK_TIMEOUT;
BEGIN TRY
    EXEC @Exec @Sql,
        N'@WindowStart datetimeoffset(7), @WindowEnd datetimeoffset(7), @MinExecs bigint, @MinCpuRatio decimal(9, 2)',
        @WindowStart = @WindowStart,
        @WindowEnd   = @WindowEnd,
        @MinExecs    = @MinExecs,
        @MinCpuRatio = @MinCpuRatio;
END TRY
BEGIN CATCH
    SET LOCK_TIMEOUT @PreviousLockTimeout;
    THROW;
END CATCH;
SET LOCK_TIMEOUT @PreviousLockTimeout;
GO
