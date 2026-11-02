CREATE OR ALTER PROCEDURE dbo.QueryStore_TopCpuCum
    @DatabaseName sysname,
    @WindowStart  datetimeoffset(7) = NULL,
    @WindowEnd    datetimeoffset(7) = NULL,
    @Top          int               = 25,
    @Debug        bit               = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
DESCRIPTION
    Ranks query_hash values by cumulative CPU consumption across the Query Store history retained
    in the selected window. When @WindowStart is NULL, the report includes all retained history
    before @WindowEnd. Per-execution CPU and logical I/O help distinguish expensive executions
    from frequently executed queries.

PARAMETERS
* @DatabaseName - Target database name. The database must have Query Store enabled.
* @WindowStart - Optional start of the reporting window. NULL includes all retained history.
* @WindowEnd - End of the reporting window. Defaults to the current time.
* @Top - Maximum number of rows to return. Defaults to 25.
* @Debug - Print the assembled dynamic SQL.

EXAMPLES:
-- Rank CPU consumers across all retained Query Store history:
-- EXEC dbo.QueryStore_TopCpuCum @DatabaseName = N'AMtwo';

-- Rank CPU consumers in a specific window:
-- EXEC dbo.QueryStore_TopCpuCum
--     @DatabaseName = N'AMtwo',
--     @WindowStart = '2026-10-01T00:00:00-04:00',
--     @WindowEnd = '2026-10-31T00:00:00-04:00',
--     @Top = 50;
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

SET @WindowEnd = ISNULL(@WindowEnd, SYSDATETIMEOFFSET());

DECLARE @Exec nvarchar(400) = QUOTENAME(@DatabaseName) + N'.sys.sp_executesql',
        @Sql  nvarchar(max);

SET @Sql = N'
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;

WITH QueryStats AS (
    SELECT
        q.query_hash,
        Execs          = SUM(rs.count_executions),
        CpuSec         = SUM(ISNULL(rs.avg_cpu_time, 0) * rs.count_executions) / 1e6,
        LogicalIoPages = SUM((ISNULL(rs.avg_logical_io_reads, 0) + ISNULL(rs.avg_logical_io_writes, 0)) * rs.count_executions)
    FROM sys.query_store_runtime_stats_interval AS rsi
    JOIN sys.query_store_runtime_stats AS rs
        ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p
        ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query AS q
        ON q.query_id = p.query_id
    WHERE (@WindowStart IS NULL OR rsi.end_time > @WindowStart)
      AND rsi.start_time < @WindowEnd
    GROUP BY q.query_hash
)
SELECT TOP (@Top)
    DatabaseName = DB_NAME(),
    qs.query_hash,
    qs.Execs,
    CpuSec               = CONVERT(decimal(18, 1), qs.CpuSec),
    CpuMsPerExec         = CONVERT(decimal(18, 2), qs.CpuSec * 1000 / NULLIF(qs.Execs, 0)),
    LogicalIoPages       = CONVERT(decimal(18, 1), qs.LogicalIoPages),
    LogicalIoPagesPerExec = CONVERT(decimal(18, 2), qs.LogicalIoPages / NULLIF(qs.Execs, 0)),
    SampleQueryId        = s.query_id,
    ObjectName           = OBJECT_SCHEMA_NAME(s.object_id) + N''.'' + OBJECT_NAME(s.object_id),
    SampleText           = LEFT(s.query_sql_text, 200)
FROM QueryStats AS qs
OUTER APPLY (
    SELECT TOP (1) q2.query_id, q2.object_id, qt.query_sql_text
    FROM sys.query_store_query AS q2
    JOIN sys.query_store_query_text AS qt
        ON qt.query_text_id = q2.query_text_id
    WHERE q2.query_hash = qs.query_hash
    ORDER BY q2.last_execution_time DESC
) AS s
ORDER BY qs.CpuSec DESC;';

IF @Debug = 1
    PRINT @Sql;

DECLARE @PreviousLockTimeout int = @@LOCK_TIMEOUT;
DECLARE @RestoreLockTimeout nvarchar(50) = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(12), @PreviousLockTimeout);
BEGIN TRY
    EXEC @Exec @Sql,
        N'@WindowStart datetimeoffset(7), @WindowEnd datetimeoffset(7), @Top int',
        @WindowStart = @WindowStart,
        @WindowEnd   = @WindowEnd,
        @Top         = @Top;
END TRY
BEGIN CATCH
    EXEC (@RestoreLockTimeout);
    THROW;
END CATCH;
EXEC (@RestoreLockTimeout);
GO
