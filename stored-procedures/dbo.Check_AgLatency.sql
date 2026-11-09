IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Check_AgLatency'))
    EXEC ('CREATE PROCEDURE dbo.Check_AgLatency AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Check_AgLatency 
    @Threshold int = 0,
    @DbName nvarchar(128) = N'%',
    @AgName nvarchar(128) = N'%',
    @UnhealthyOnly bit = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20140409
       This Alert checks AG latency (unsent logs). 
       Latency is based on the worst reported condition from both DMVs & perfmon.

PARAMETERS
* @Threshold - Default 0 - Minimum unsent log KB. Zero includes unavailable queue measurements.
* @DbName        - Default % (anything) - Filter by DbName, Can be wildcarded
* @AgName        - Default % (anything) - Filter by AgName, Can be wildcarded
* @UnhealthyOnly - Default 0 (false) - Only select databases that have sync status of NOT HEALTHY
EXAMPLES:
*
**************************************************************************************************
MODIFICATIONS:
    20140804 - Start tracking Hardened LSN from DMV each time sproc runs. 
    20150107 - Add calculation for "minutes behind" to show how far behind primary a DB is
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

CREATE TABLE #Results (
    ServerName sysname,
    AgName sysname,
    DbName sysname,
    UnsentLogKb bigint,
    SynchState nvarchar(60),
    AgHealth nvarchar(60),
    SuspendReason nvarchar(60),
    LastHardenedTime datetime2(3),
    LastRedoneTime datetime2(3),
    RedoEstSecCompletion bigint,
    LastCommitTime datetime2(3),
    MinutesBehind int,
    SortOrder int
    );


-- Replica state is the source of rows. Queue counters only supplement it.
WITH ReplicaStatus AS (
    SELECT ar.replica_server_name AS ServerName,
           ag.name AS AgName,
           adc.database_name AS DbName,
           ds.group_id AS GroupId,
           ds.group_database_id AS GroupDatabaseId,
           ds.is_local AS IsLocal,
           ds.is_primary_replica AS IsPrimary,
           ds.log_send_queue_size AS LogSendQueueKb,
           ds.synchronization_state_desc AS SynchState,
           ds.synchronization_health_desc AS AgHealth,
           ds.suspend_reason_desc AS SuspendReason,
           ds.last_hardened_time AS LastHardenedTime,
           ds.last_redone_time AS LastRedoneTime,
           CASE WHEN ds.redo_rate = 0 THEN 0 ELSE ds.redo_queue_size / ds.redo_rate END AS RedoEstSecCompletion,
           ds.last_commit_time AS LastCommitTime
    FROM sys.dm_hadr_database_replica_states AS ds
    JOIN sys.availability_groups AS ag ON ag.group_id = ds.group_id
    JOIN sys.availability_replicas AS ar ON ar.group_id = ds.group_id AND ar.replica_id = ds.replica_id
    JOIN sys.availability_databases_cluster AS adc
        ON adc.group_id = ds.group_id AND adc.group_database_id = ds.group_database_id
)
INSERT INTO #Results (ServerName, AgName, DbName, UnsentLogKb, SynchState, AgHealth, SuspendReason,
                      LastHardenedTime, LastRedoneTime, RedoEstSecCompletion, LastCommitTime, MinutesBehind, SortOrder)
SELECT r.ServerName,
       r.AgName,
       r.DbName,
       q.UnsentLogKb,
       r.SynchState,
       r.AgHealth,
       r.SuspendReason,
       r.LastHardenedTime,
       r.LastRedoneTime,
       r.RedoEstSecCompletion,
       r.LastCommitTime,
       CASE
           WHEN r.IsPrimary = 1 THEN 0
           WHEN r.LastCommitTime > p.LastCommitTime THEN 0
           ELSE DATEDIFF(MINUTE, r.LastCommitTime, p.LastCommitTime)
       END,
       CASE
           WHEN q.UnsentLogKb > 1000 THEN 2
           WHEN r.AgHealth <> N'HEALTHY' THEN 3
           WHEN r.SynchState NOT IN (N'SYNCHRONIZING', N'SYNCHRONIZED') THEN 4
           ELSE 5
       END
FROM ReplicaStatus AS r
LEFT JOIN ReplicaStatus AS p
    ON p.GroupId = r.GroupId AND p.GroupDatabaseId = r.GroupDatabaseId AND p.IsPrimary = 1
OUTER APPLY (
    SELECT MAX(pc.cntr_value) AS QueueKb
    FROM sys.dm_os_performance_counters AS pc
    WHERE r.IsLocal = 1
      AND pc.object_name LIKE N'%:Database Replica'
      AND pc.counter_name = N'Log Send Queue'
      AND LTRIM(RTRIM(pc.instance_name)) = r.DbName COLLATE DATABASE_DEFAULT
) AS perf
CROSS APPLY (
    SELECT MAX(v.QueueKb) AS UnsentLogKb
    FROM (VALUES (r.LogSendQueueKb), (perf.QueueKb)) AS v(QueueKb)
) AS q;

--Output results
-- Do filtering on the results here, rather than up above. 
-- There's not much data here, so no perf advantage to doing it sooner.
    IF NOT EXISTS (SELECT 1 FROM #Results)
        SELECT 'No AGs Exist' AS AgStatus;
    ELSE
        SELECT * 
        FROM #Results AS r
        WHERE (r.UnsentLogKb >= @Threshold OR (@Threshold = 0 AND r.UnsentLogKb IS NULL))
        AND r.DbName LIKE @DbName
        AND r.AgName LIKE @AgName
        AND r.DbName = CASE
                        WHEN @UnhealthyOnly = 0 
                            THEN r.DbName
                        WHEN EXISTS (SELECT 1 FROM #Results r2
                                    WHERE r2.AgHealth <> 'HEALTHY'
                                    AND r2.AgName = r.AgName
                                    AND r2.DbName = r.DbName)
                            THEN r.DbName
                      END
        ORDER BY SortOrder, UnsentLogKb DESC, ServerName, DbName;
GO
