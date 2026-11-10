CREATE OR ALTER PROCEDURE dbo.QueryStore_TopIoDelta
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
    Ranks Query Store logical I/O page activity by query_hash in a time window and compares each
    query with the same-length window @CompareOffsetHours earlier. The total includes logical
    reads and writes; these are also returned separately, along with physical reads. I/O per
    execution helps distinguish changed query efficiency from increased execution volume.
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
-- Compare the default one-hour window with the same hour one week earlier:
-- EXEC dbo.QueryStore_TopIoDelta @DatabaseName = N'AMtwo';

-- Compare a two-hour window and return the top 50 logical I/O deltas:
-- EXEC dbo.QueryStore_TopIoDelta
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
        LogicalReads  = SUM(rs.avg_logical_io_reads * rs.count_executions),
        LogicalWrites = SUM(rs.avg_logical_io_writes * rs.count_executions),
        PhysicalReads = SUM(rs.avg_physical_io_reads * rs.count_executions)
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
        BaseExecs          = ISNULL(SUM(CASE WHEN ws.IsNow = 0 THEN ws.Execs END), 0),
        NowExecs           = ISNULL(SUM(CASE WHEN ws.IsNow = 1 THEN ws.Execs END), 0),
        BaseLogicalReads   = ISNULL(SUM(CASE WHEN ws.IsNow = 0 THEN ws.LogicalReads END), 0),
        NowLogicalReads    = ISNULL(SUM(CASE WHEN ws.IsNow = 1 THEN ws.LogicalReads END), 0),
        BaseLogicalWrites  = ISNULL(SUM(CASE WHEN ws.IsNow = 0 THEN ws.LogicalWrites END), 0),
        NowLogicalWrites   = ISNULL(SUM(CASE WHEN ws.IsNow = 1 THEN ws.LogicalWrites END), 0),
        BasePhysicalReads  = ISNULL(SUM(CASE WHEN ws.IsNow = 0 THEN ws.PhysicalReads END), 0),
        NowPhysicalReads   = ISNULL(SUM(CASE WHEN ws.IsNow = 1 THEN ws.PhysicalReads END), 0)
    FROM WindowStats AS ws
    GROUP BY ws.query_hash
),
Totals AS (
    SELECT
        pv.*,
        BaseLogicalIoPages = pv.BaseLogicalReads + pv.BaseLogicalWrites,
        NowLogicalIoPages  = pv.NowLogicalReads + pv.NowLogicalWrites
    FROM Pivoted AS pv
)
SELECT TOP (@Top)
    DatabaseName = DB_NAME(),
    t.query_hash,
    t.BaseExecs,
    t.NowExecs,
    BaseLogicalIoPages = CONVERT(decimal(18, 1), t.BaseLogicalIoPages),
    NowLogicalIoPages  = CONVERT(decimal(18, 1), t.NowLogicalIoPages),
    DeltaLogicalIoPages = CONVERT(decimal(18, 1), t.NowLogicalIoPages - t.BaseLogicalIoPages),
    BaseLogicalReads   = CONVERT(decimal(18, 1), t.BaseLogicalReads),
    NowLogicalReads    = CONVERT(decimal(18, 1), t.NowLogicalReads),
    DeltaLogicalReads  = CONVERT(decimal(18, 1), t.NowLogicalReads - t.BaseLogicalReads),
    BaseLogicalWrites  = CONVERT(decimal(18, 1), t.BaseLogicalWrites),
    NowLogicalWrites   = CONVERT(decimal(18, 1), t.NowLogicalWrites),
    DeltaLogicalWrites = CONVERT(decimal(18, 1), t.NowLogicalWrites - t.BaseLogicalWrites),
    BasePhysicalReads  = CONVERT(decimal(18, 1), t.BasePhysicalReads),
    NowPhysicalReads   = CONVERT(decimal(18, 1), t.NowPhysicalReads),
    DeltaPhysicalReads = CONVERT(decimal(18, 1), t.NowPhysicalReads - t.BasePhysicalReads),
    NowLogicalIoPagesPerExec = CONVERT(decimal(18, 2), t.NowLogicalIoPages / NULLIF(t.NowExecs, 0)),
    BaseLogicalIoPagesPerExec = CONVERT(decimal(18, 2), t.BaseLogicalIoPages / NULLIF(t.BaseExecs, 0)),
    IoPerExecRatio = CONVERT(decimal(18, 2), (t.NowLogicalIoPages / NULLIF(t.NowExecs, 0))
                                               / NULLIF(t.BaseLogicalIoPages / NULLIF(t.BaseExecs, 0), 0)),
    ExecRatio      = CONVERT(decimal(18, 2), t.NowExecs * 1.0 / NULLIF(t.BaseExecs, 0)),
    IsNewQuery     = CASE WHEN t.BaseExecs = 0 THEN 1 ELSE 0 END,
    SampleQueryId  = s.query_id,
    ObjectName     = OBJECT_SCHEMA_NAME(s.object_id) + N''.'' + OBJECT_NAME(s.object_id),
    SampleText     = LEFT(s.query_sql_text, 200)
FROM Totals AS t
OUTER APPLY (
    SELECT TOP (1) q2.query_id, q2.object_id, qt.query_sql_text
    FROM sys.query_store_query AS q2
    JOIN sys.query_store_query_text AS qt
        ON qt.query_text_id = q2.query_text_id
    WHERE q2.query_hash = t.query_hash
    ORDER BY q2.last_execution_time DESC
) AS s
ORDER BY DeltaLogicalIoPages DESC;';

IF @Debug = 1
BEGIN
    PRINT @Sql;
END;

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
