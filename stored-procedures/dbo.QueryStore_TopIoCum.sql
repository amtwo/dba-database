CREATE OR ALTER PROCEDURE dbo.QueryStore_TopIoCum
    @DatabaseName sysname,
    @WindowStart  datetimeoffset(7) = NULL,
    @WindowEnd    datetimeoffset(7) = NULL,
    @Top          int               = 25,
    @Debug        bit               = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
DESCRIPTION
    Ranks query_hash values by cumulative logical I/O page activity across the Query Store history
    retained in the selected window. The total combines logical reads and writes; both components
    and physical reads are also returned. When @WindowStart is NULL, all retained history before
    @WindowEnd is included. Per-execution logical I/O helps identify changes in query efficiency.

PARAMETERS
* @DatabaseName - Target database name. The database must have Query Store enabled.
* @WindowStart - Optional start of the reporting window. NULL includes all retained history.
* @WindowEnd - End of the reporting window. Defaults to the current time.
* @Top - Maximum number of rows to return. Defaults to 25.
* @Debug - Print the assembled dynamic SQL.

EXAMPLES:
-- Rank logical I/O consumers across all retained Query Store history:
-- EXEC dbo.QueryStore_TopIoCum @DatabaseName = N'AMtwo';

-- Rank logical I/O consumers in a specific window:
-- EXEC dbo.QueryStore_TopIoCum
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
        Execs         = SUM(rs.count_executions),
        LogicalReads  = SUM(ISNULL(rs.avg_logical_io_reads, 0) * rs.count_executions),
        LogicalWrites = SUM(ISNULL(rs.avg_logical_io_writes, 0) * rs.count_executions),
        PhysicalReads = SUM(ISNULL(rs.avg_physical_io_reads, 0) * rs.count_executions)
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
),
Totals AS (
    SELECT
        qs.*,
        LogicalIoPages = qs.LogicalReads + qs.LogicalWrites
    FROM QueryStats AS qs
)
SELECT TOP (@Top)
    t.query_hash,
    t.Execs,
    LogicalIoPages       = CONVERT(decimal(18, 1), t.LogicalIoPages),
    LogicalReads         = CONVERT(decimal(18, 1), t.LogicalReads),
    LogicalWrites        = CONVERT(decimal(18, 1), t.LogicalWrites),
    PhysicalReads        = CONVERT(decimal(18, 1), t.PhysicalReads),
    LogicalIoPagesPerExec = CONVERT(decimal(18, 2), t.LogicalIoPages / NULLIF(t.Execs, 0)),
    LogicalReadsPerExec  = CONVERT(decimal(18, 2), t.LogicalReads / NULLIF(t.Execs, 0)),
    LogicalWritesPerExec = CONVERT(decimal(18, 2), t.LogicalWrites / NULLIF(t.Execs, 0)),
    SampleQueryId        = s.query_id,
    ObjectName           = OBJECT_SCHEMA_NAME(s.object_id) + N''.'' + OBJECT_NAME(s.object_id),
    SampleText           = LEFT(s.query_sql_text, 200)
FROM Totals AS t
OUTER APPLY (
    SELECT TOP (1) q2.query_id, q2.object_id, qt.query_sql_text
    FROM sys.query_store_query AS q2
    JOIN sys.query_store_query_text AS qt
        ON qt.query_text_id = q2.query_text_id
    WHERE q2.query_hash = t.query_hash
    ORDER BY q2.last_execution_time DESC
) AS s
ORDER BY t.LogicalIoPages DESC;';

IF @Debug = 1
    PRINT @Sql;

DECLARE @PreviousLockTimeout int = @@LOCK_TIMEOUT;
BEGIN TRY
    EXEC @Exec @Sql,
        N'@WindowStart datetimeoffset(7), @WindowEnd datetimeoffset(7), @Top int',
        @WindowStart = @WindowStart,
        @WindowEnd   = @WindowEnd,
        @Top         = @Top;
END TRY
BEGIN CATCH
    SET LOCK_TIMEOUT @PreviousLockTimeout;
    THROW;
END CATCH;
SET LOCK_TIMEOUT @PreviousLockTimeout;
GO
