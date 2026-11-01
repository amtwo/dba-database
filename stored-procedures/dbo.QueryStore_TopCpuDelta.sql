CREATE OR ALTER PROCEDURE dbo.QueryStore_TopCpuDelta
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
    Ranks Query Store CPU consumers by query_hash in a time window and compares each with the
    same-length window @CompareOffsetHours earlier. A high CPU-per-execution ratio suggests a
    per-execution regression; a high CPU delta with a ratio near one suggests increased workload.
    Query Store buckets runtime statistics by interval, so intervals overlapping either window
    are included. Use whole-interval windows when you need the cleanest comparison.

PARAMETERS
* @DatabaseName - Target database name. The database must have Query Store enabled.
* @WindowStart - Start of the current window. Defaults to one hour before @WindowEnd.
* @WindowEnd - End of the current window. Defaults to the current time.
* @CompareOffsetHours - Hours to shift the comparison window back. Defaults to 168 (one week).
  Set it at least as large as the window length to avoid overlapping windows.
* @Top - Maximum number of rows to return. Defaults to 25.
* @Debug - Print the assembled dynamic SQL.

EXAMPLES:
-- Compare the default one-hour window with the same hour one week earlier:
-- EXEC dbo.QueryStore_TopCpuDelta @DatabaseName = N'AMtwo';

-- Compare a two-hour window with the same period one week earlier:
-- EXEC dbo.QueryStore_TopCpuDelta
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

SET @WindowEnd   = ISNULL(@WindowEnd, SYSDATETIMEOFFSET());
SET @WindowStart = ISNULL(@WindowStart, DATEADD(HOUR, -1, @WindowEnd));

DECLARE @BaseStart datetimeoffset(7) = DATEADD(HOUR, -@CompareOffsetHours, @WindowStart),
        @BaseEnd   datetimeoffset(7) = DATEADD(HOUR, -@CompareOffsetHours, @WindowEnd),
        @Exec      nvarchar(400)     = QUOTENAME(@DatabaseName) + N'.sys.sp_executesql',
        @Sql       nvarchar(max);

SET @Sql = N'
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;

WITH WindowStats AS (
    SELECT
        q.query_hash,
        IsNow  = CASE WHEN rsi.end_time > @WindowStart THEN 1 ELSE 0 END,
        Execs  = SUM(rs.count_executions),
        CpuSec = SUM(rs.avg_cpu_time * rs.count_executions) / 1e6
    FROM sys.query_store_runtime_stats_interval AS rsi
    JOIN sys.query_store_runtime_stats AS rs
        ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p
        ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query AS q
        ON q.query_id = p.query_id
    WHERE (rsi.end_time > @WindowStart AND rsi.start_time < @WindowEnd)
       OR (rsi.end_time > @BaseStart   AND rsi.start_time < @BaseEnd)
    GROUP BY q.query_hash, CASE WHEN rsi.end_time > @WindowStart THEN 1 ELSE 0 END
),
Pivoted AS (
    SELECT
        ws.query_hash,
        BaseExecs  = ISNULL(SUM(CASE WHEN ws.IsNow = 0 THEN ws.Execs END), 0),
        NowExecs   = ISNULL(SUM(CASE WHEN ws.IsNow = 1 THEN ws.Execs END), 0),
        BaseCpuSec = ISNULL(SUM(CASE WHEN ws.IsNow = 0 THEN ws.CpuSec END), 0),
        NowCpuSec  = ISNULL(SUM(CASE WHEN ws.IsNow = 1 THEN ws.CpuSec END), 0)
    FROM WindowStats AS ws
    GROUP BY ws.query_hash
)
SELECT TOP (@Top)
    pv.query_hash,
    pv.BaseExecs,
    pv.NowExecs,
    BaseCpuSec        = CONVERT(decimal(18, 1), pv.BaseCpuSec),
    NowCpuSec         = CONVERT(decimal(18, 1), pv.NowCpuSec),
    DeltaCpuSec       = CONVERT(decimal(18, 1), pv.NowCpuSec - pv.BaseCpuSec),
    NowCpuMsPerExec   = CONVERT(decimal(18, 2), pv.NowCpuSec * 1000 / NULLIF(pv.NowExecs, 0)),
    BaseCpuMsPerExec  = CONVERT(decimal(18, 2), pv.BaseCpuSec * 1000 / NULLIF(pv.BaseExecs, 0)),
    CpuPerExecRatio   = CONVERT(decimal(18, 2), (pv.NowCpuSec / NULLIF(pv.NowExecs, 0))
                                               / NULLIF(pv.BaseCpuSec / NULLIF(pv.BaseExecs, 0), 0)),
    ExecRatio         = CONVERT(decimal(18, 2), pv.NowExecs * 1.0 / NULLIF(pv.BaseExecs, 0)),
    IsNewQuery        = CASE WHEN pv.BaseExecs = 0 THEN 1 ELSE 0 END,
    SampleQueryId     = s.query_id,
    ObjectName        = OBJECT_SCHEMA_NAME(s.object_id) + N''.'' + OBJECT_NAME(s.object_id),
    SampleText        = LEFT(s.query_sql_text, 200)
FROM Pivoted AS pv
OUTER APPLY (
    SELECT TOP (1) q2.query_id, q2.object_id, qt.query_sql_text
    FROM sys.query_store_query AS q2
    JOIN sys.query_store_query_text AS qt
        ON qt.query_text_id = q2.query_text_id
    WHERE q2.query_hash = pv.query_hash
    ORDER BY q2.last_execution_time DESC
) AS s
ORDER BY DeltaCpuSec DESC;';

IF @Debug = 1
    PRINT @Sql;

DECLARE @PreviousLockTimeout int = @@LOCK_TIMEOUT;
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
    SET LOCK_TIMEOUT @PreviousLockTimeout;
    THROW;
END CATCH;
SET LOCK_TIMEOUT @PreviousLockTimeout;
GO
