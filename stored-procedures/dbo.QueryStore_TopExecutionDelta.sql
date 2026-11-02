CREATE OR ALTER PROCEDURE dbo.QueryStore_TopExecutionDelta
    @DatabaseName       sysname,
    @WindowStart        datetimeoffset(7) = NULL,
    @WindowEnd          datetimeoffset(7) = NULL,
    @CompareOffsetHours int               = 168,
    @Top                int               = 25,
    @Debug              bit               = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
DESCRIPTION
    Ranks query_hash values by the change in execution count between a time window and the
    same-length window @CompareOffsetHours earlier. Execution count measures workload volume,
    not per-execution efficiency, so the output also includes CPU and logical I/O per execution
    for both windows to help distinguish more executions from costlier executions.
    Only intervals wholly contained in either window are included.

PARAMETERS
* @DatabaseName - Target database name. The database must have Query Store enabled.
* @WindowStart - Start of the current window. Defaults to one hour before @WindowEnd.
* @WindowEnd - End of the current window. Defaults to the target database's current interval start.
  If no interval is active, uses the latest completed interval end.
* @CompareOffsetHours - Hours to shift the comparison window back. Defaults to 168 (one week).
  Set it at least as large as the window length to avoid overlapping windows.
* @Top - Maximum number of rows to return. Defaults to 25.
* @Debug - Print the assembled dynamic SQL.

EXAMPLES:
-- Compare the default one-hour execution volume window with the same hour one week earlier:
-- EXEC dbo.QueryStore_TopExecutionDelta @DatabaseName = N'AMtwo';

-- Compare a custom period and return the largest execution-count changes:
-- EXEC dbo.QueryStore_TopExecutionDelta
--     @DatabaseName = N'AMtwo',
--     @WindowStart = '2026-10-31T08:00:00-04:00',
--     @WindowEnd = '2026-10-31T10:00:00-04:00',
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

DECLARE @Exec nvarchar(400) = QUOTENAME(@DatabaseName) + N'.sys.sp_executesql',
        @Sql  nvarchar(max);

IF @WindowEnd IS NULL
BEGIN
    -- Stop at the active interval's start, or the latest completed end if no interval is active.
    EXEC @Exec
        N'DECLARE @AsOf datetimeoffset(7) = SYSDATETIMEOFFSET();
          SELECT @WindowEnd = MAX(CASE WHEN rsi.end_time > @AsOf THEN rsi.start_time ELSE rsi.end_time END)
          FROM sys.query_store_runtime_stats_interval AS rsi
          WHERE rsi.start_time <= @AsOf;',
        N'@WindowEnd datetimeoffset(7) OUTPUT',
        @WindowEnd = @WindowEnd OUTPUT;
END;
SET @WindowStart = ISNULL(@WindowStart, DATEADD(HOUR, -1, @WindowEnd));

DECLARE @BaseStart datetimeoffset(7) = DATEADD(HOUR, -@CompareOffsetHours, @WindowStart),
        @BaseEnd   datetimeoffset(7) = DATEADD(HOUR, -@CompareOffsetHours, @WindowEnd);

SET @Sql = N'
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;

WITH WindowStats AS (
    SELECT
        q.query_hash,
        IsNow         = CASE WHEN rsi.start_time >= @WindowStart AND rsi.end_time <= @WindowEnd THEN 1 ELSE 0 END,
        Execs         = SUM(rs.count_executions),
        CpuUs         = SUM(rs.avg_cpu_time * rs.count_executions),
        LogicalIoPages = SUM((rs.avg_logical_io_reads + rs.avg_logical_io_writes) * rs.count_executions)
    FROM sys.query_store_runtime_stats_interval AS rsi
    JOIN sys.query_store_runtime_stats AS rs
        ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p
        ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query AS q
        ON q.query_id = p.query_id
    WHERE (rsi.start_time >= @WindowStart AND rsi.end_time <= @WindowEnd)
       OR (rsi.start_time >= @BaseStart   AND rsi.end_time <= @BaseEnd)
    GROUP BY q.query_hash, CASE WHEN rsi.start_time >= @WindowStart AND rsi.end_time <= @WindowEnd THEN 1 ELSE 0 END
),
Pivoted AS (
    SELECT
        ws.query_hash,
        BaseExecs            = ISNULL(SUM(CASE WHEN ws.IsNow = 0 THEN ws.Execs END), 0),
        NowExecs             = ISNULL(SUM(CASE WHEN ws.IsNow = 1 THEN ws.Execs END), 0),
        BaseCpuUs            = ISNULL(SUM(CASE WHEN ws.IsNow = 0 THEN ws.CpuUs END), 0),
        NowCpuUs             = ISNULL(SUM(CASE WHEN ws.IsNow = 1 THEN ws.CpuUs END), 0),
        BaseLogicalIoPages   = ISNULL(SUM(CASE WHEN ws.IsNow = 0 THEN ws.LogicalIoPages END), 0),
        NowLogicalIoPages    = ISNULL(SUM(CASE WHEN ws.IsNow = 1 THEN ws.LogicalIoPages END), 0)
    FROM WindowStats AS ws
    GROUP BY ws.query_hash
)
SELECT TOP (@Top)
    DatabaseName = DB_NAME(),
    pv.query_hash,
    pv.BaseExecs,
    pv.NowExecs,
    DeltaExecs = pv.NowExecs - pv.BaseExecs,
    ExecRatio  = CONVERT(decimal(18, 2), pv.NowExecs * 1.0 / NULLIF(pv.BaseExecs, 0)),
    IsNewQuery = CASE WHEN pv.BaseExecs = 0 THEN 1 ELSE 0 END,
    NowCpuMsPerExec = CONVERT(decimal(18, 2), pv.NowCpuUs / NULLIF(pv.NowExecs, 0) / 1000.0),
    BaseCpuMsPerExec = CONVERT(decimal(18, 2), pv.BaseCpuUs / NULLIF(pv.BaseExecs, 0) / 1000.0),
    CpuPerExecRatio = CONVERT(decimal(18, 2), (pv.NowCpuUs / NULLIF(pv.NowExecs, 0))
                                               / NULLIF(pv.BaseCpuUs / NULLIF(pv.BaseExecs, 0), 0)),
    NowLogicalIoPagesPerExec = CONVERT(decimal(18, 2), pv.NowLogicalIoPages / NULLIF(pv.NowExecs, 0)),
    BaseLogicalIoPagesPerExec = CONVERT(decimal(18, 2), pv.BaseLogicalIoPages / NULLIF(pv.BaseExecs, 0)),
    IoPerExecRatio = CONVERT(decimal(18, 2), (pv.NowLogicalIoPages / NULLIF(pv.NowExecs, 0))
                                             / NULLIF(pv.BaseLogicalIoPages / NULLIF(pv.BaseExecs, 0), 0)),
    SampleQueryId = s.query_id,
    ObjectName    = OBJECT_SCHEMA_NAME(s.object_id) + N''.'' + OBJECT_NAME(s.object_id),
    SampleText    = LEFT(s.query_sql_text, 200)
FROM Pivoted AS pv
OUTER APPLY (
    SELECT TOP (1) q2.query_id, q2.object_id, qt.query_sql_text
    FROM sys.query_store_query AS q2
    JOIN sys.query_store_query_text AS qt
        ON qt.query_text_id = q2.query_text_id
    WHERE q2.query_hash = pv.query_hash
    ORDER BY q2.last_execution_time DESC
) AS s
ORDER BY DeltaExecs DESC;';

IF @Debug = 1
    PRINT @Sql;

DECLARE @PreviousLockTimeout int = @@LOCK_TIMEOUT;
DECLARE @RestoreLockTimeout nvarchar(50) = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(12), @PreviousLockTimeout);
BEGIN TRY
    EXEC @Exec @Sql,
        N'@WindowStart datetimeoffset(7), @WindowEnd datetimeoffset(7), @BaseStart datetimeoffset(7), @BaseEnd datetimeoffset(7), @Top int',
        @WindowStart = @WindowStart,
        @WindowEnd   = @WindowEnd,
        @BaseStart   = @BaseStart,
        @BaseEnd     = @BaseEnd,
        @Top         = @Top;
END TRY
BEGIN CATCH
    EXEC (@RestoreLockTimeout);
    THROW;
END CATCH;
EXEC (@RestoreLockTimeout);
GO
