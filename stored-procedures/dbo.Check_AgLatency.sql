CREATE OR ALTER PROCEDURE dbo.Check_AgLatency
    @Threshold int = 5000,
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
* @Threshold - Default 5000 - Minimum unsent log KB. Unknown queues always pass the threshold and sort first.
* @DbName        - Default % (anything) - Filter by DbName, Can be wildcarded
* @AgName        - Default % (anything) - Filter by AgName, Can be wildcarded
* @UnhealthyOnly - Default 0 (false) - Only select databases with a replica that is unhealthy or has an unknown send queue.
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

DECLARE 
    @ProductVersion tinyint;

SET @ProductVersion = LEFT(CAST(SERVERPROPERTY('PRODUCTVERSION') AS varchar(20)),CHARINDEX('.',CAST(SERVERPROPERTY('PRODUCTVERSION') AS varchar(20)))-1)

IF @ProductVersion < 11
BEGIN
    SELECT 'SQL Server version does not support AGs';
    RETURN;
END;
    
CREATE TABLE #AgStatus ( --drop table #AgStatus
    RunDate smalldatetime NOT NULL ,
    ServerName sysname NOT NULL ,
    AgName sysname NOT NULL,
    DbName sysname NOT NULL ,
    IsPrimary bit NULL,
    AgRole nvarchar(60) NULL,
    SynchState nvarchar(60) NULL,
    AgHealth nvarchar(60) NULL,
    SuspendReason nvarchar(60) NULL,
    SynchHardenedLSN numeric(25,0) NULL,
    LastHardenedTime datetime2(3) NULL,
    LastRedoneTime datetime2(3) NULL,
    RedoEstSecCompletion bigint NULL,
    LastCommitTime datetime2(3) NULL,
    PRIMARY KEY  CLUSTERED (RunDate, ServerName, DBName)
    );

CREATE TABLE #SendStatus (
    ServerName sysname,
    DbName sysname,
    UnsentLogKb bigint
    );

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
    SortOrder int,
    AgRole nvarchar(60)
    );


-- Grab the current status from DMVs for AGs
-- In a distributed AG, "ServerName" is the AG name we're sending to.
INSERT INTO #AgStatus (RunDate, ServerName, AgName, DbName, IsPrimary, AgRole, SynchState, AgHealth, SuspendReason,
                      SynchHardenedLSN, LastHardenedTime, LastRedoneTime, RedoEstSecCompletion,LastCommitTime)
    SELECT GETDATE() AS RunDate, 
           ar.replica_server_name AS ServerName, 
           ag.Name                        COLLATE SQL_Latin1_General_CP1_CI_AS AS AgName,
           COALESCE(adc.database_name, DB_NAME(drs.database_id)) AS DbName,
           drs.is_primary_replica AS IsPrimary,
           rs.role_desc AS AgRole,
           drs.synchronization_state_desc  COLLATE SQL_Latin1_General_CP1_CI_AS AS SynchState,
           drs.synchronization_health_desc COLLATE SQL_Latin1_General_CP1_CI_AS AS AgHealth,
           drs.suspend_reason_desc        COLLATE SQL_Latin1_General_CP1_CI_AS AS SuspendReason,
           drs.last_hardened_lsn  AS SynchHardenedLSN,
           drs.last_hardened_time AS LastHardenedTime,
           drs.last_redone_time AS LastRedoneTime,
           CASE WHEN drs.redo_rate = 0 THEN 0 ELSE drs.redo_queue_size/drs.redo_rate END AS RedoEstCompletion,
           drs.last_commit_time AS LastCommitTime
    FROM sys.availability_groups AS ag
    JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id 
    JOIN sys.dm_hadr_database_replica_states AS drs ON drs.group_id = ar.group_id AND drs.replica_id = ar.replica_id
    LEFT JOIN sys.dm_hadr_availability_replica_states AS rs ON rs.group_id = drs.group_id AND rs.replica_id = drs.replica_id
    LEFT JOIN sys.availability_databases_cluster AS adc
        ON adc.group_id = drs.group_id AND adc.group_database_id = drs.group_database_id
    WHERE COALESCE(adc.database_name, DB_NAME(drs.database_id)) IS NOT NULL;
    

--Lets make this easy, and create a temp table with the current status
-- UNION perfmon counters with dbm_monitor_data. They should be the same, but we don't trust them, so we check both.
INSERT INTO #SendStatus (ServerName, DbName, UnsentLogKb)
SELECT ar.replica_server_name AS ServerName,
        COALESCE(adc.database_name, DB_NAME(drs.database_id)) AS DbName,
        drs.log_send_queue_size AS UnsentLogKb
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
LEFT JOIN sys.availability_databases_cluster AS adc
    ON adc.group_id = drs.group_id AND adc.group_database_id = drs.group_database_id
WHERE drs.log_send_queue_size IS NOT NULL
  AND COALESCE(adc.database_name, DB_NAME(drs.database_id)) IS NOT NULL
UNION
SELECT @@SERVERNAME,
        LTRIM(RTRIM(pc.instance_name)) as DbName,
        pc.cntr_value AS UnsentLogKb
FROM sys.[dm_os_performance_counters] AS pc
WHERE pc.object_name LIKE N'%:Database Replica'
AND pc.counter_name  = 'Log Send Queue';

INSERT INTO #Results (ServerName, AgName, DbName, UnsentLogKb, SynchState, AgHealth, SuspendReason, 
                      LastHardenedTime, LastRedoneTime, RedoEstSecCompletion, LastCommitTime, SortOrder, AgRole)
SELECT COALESCE(ags.ServerName, @@SERVERNAME) AS ServerName,
       COALESCE(ags.AgName,'') AS AgName,
       COALESCE(sync.DbName, ags.DbName) AS DbName,
       MAX(sync.UnsentLogKb) AS UnsentLogKb,
       COALESCE(ags.SynchState,'') AS SynchState,
       COALESCE(ags.AgHealth,'') AS AgHealth,
       COALESCE(ags.SuspendReason,'') AS SuspendReason,
       MAX(ags.LastHardenedTime),
       MAX(ags.LastRedoneTime),
       MAX(ags.RedoEstSecCompletion),
       MAX(ags.LastCommitTime),
       CASE
            WHEN MAX(sync.UnsentLogKb) IS NULL THEN -1
            WHEN COALESCE(sync.DbName, ags.DbName) = '_Total' THEN 0
            WHEN MAX(sync.UnsentLogKb) > 1000 THEN 2
            WHEN COALESCE(ags.AgHealth,'') <> 'HEALTHY' THEN 3
            WHEN COALESCE(ags.SynchState,'') NOT IN ('SYNCHRONIZING','SYNCHRONIZED') THEN 4
            ELSE 5
       END AS SortOrder,
       MAX(ags.AgRole) AS AgRole
FROM #SendStatus AS sync
FULL OUTER JOIN #AgStatus AS ags ON sync.ServerName = ags.ServerName AND sync.DbName = ags.DbName
GROUP BY COALESCE(ags.ServerName,@@SERVERNAME),  COALESCE(ags.AgName,''), COALESCE(sync.DbName, ags.DbName),COALESCE(ags.SynchState,''), COALESCE(ags.AgHealth,''),
          COALESCE(ags.SuspendReason,'') ;

UPDATE r
SET MinutesBehind = CASE WHEN r.LastCommitTime > primaryStatus.LastCommitTime THEN 0
                         ELSE DATEDIFF(MINUTE, r.LastCommitTime, primaryStatus.LastCommitTime) END
FROM #Results AS r
JOIN #AgStatus AS primaryStatus ON primaryStatus.AgName = r.AgName AND primaryStatus.DbName = r.DbName AND primaryStatus.IsPrimary = 1;



--Output results
-- Do filtering on the results here, rather than up above. 
-- There's not much data here, so no perf advantage to doing it sooner.
    IF NOT EXISTS (SELECT 1 FROM #Results AS r)
        SELECT 'No AGs Exist' AS AgStatus;
    ELSE
        SELECT r.*
        FROM #Results AS r
        WHERE (r.UnsentLogKb IS NULL OR r.UnsentLogKb >= @Threshold)
        AND r.DbName LIKE @DbName
        AND r.AgName LIKE @AgName
        AND r.DbName = CASE
                        WHEN @UnhealthyOnly = 0 
                            THEN r.DbName
                        WHEN EXISTS (SELECT 1 FROM #Results AS peer
                                    WHERE (peer.AgHealth <> 'HEALTHY' OR peer.UnsentLogKb IS NULL)
                                    AND peer.AgName = r.AgName
                                    AND peer.DbName = r.DbName)
                            THEN r.DbName
                      END
        ORDER BY r.SortOrder, r.UnsentLogKb DESC, r.ServerName, r.DbName;
GO
