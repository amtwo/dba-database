IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Check_AgLatency'))
    EXEC ('CREATE PROCEDURE dbo.Check_AgLatency AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Check_AgLatency 
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
           COALESCE(adc.database_name, DB_NAME(ds.database_id)) AS DbName,
           ds.is_primary_replica AS IsPrimary,
           rs.role_desc AS AgRole,
           ds.synchronization_state_desc  COLLATE SQL_Latin1_General_CP1_CI_AS AS SynchState, 
           ds.synchronization_health_desc COLLATE SQL_Latin1_General_CP1_CI_AS AS AgHealth, 
           ds. suspend_reason_desc        COLLATE SQL_Latin1_General_CP1_CI_AS AS SuspendReason, 
           ds.last_hardened_lsn  AS SynchHardenedLSN,
           ds.last_hardened_time AS LastHardenedTime,
           ds.last_redone_time AS LastRedoneTime,
           CASE WHEN redo_rate = 0 THEN 0 ELSE ds.redo_queue_size/ds.redo_rate END AS RedoEstCompletion,
           ds.last_commit_time AS LastCommitTime
    FROM sys.availability_groups AS ag
    JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id 
    JOIN sys.dm_hadr_database_replica_states AS ds ON ds.group_id = ar.group_id AND ds.replica_id = ar.replica_id
    LEFT JOIN sys.dm_hadr_availability_replica_states AS rs ON rs.group_id = ds.group_id AND rs.replica_id = ds.replica_id
    LEFT JOIN sys.availability_databases_cluster AS adc
        ON adc.group_id = ds.group_id AND adc.group_database_id = ds.group_database_id
    WHERE COALESCE(adc.database_name, DB_NAME(ds.database_id)) IS NOT NULL;
    

--Lets make this easy, and create a temp table with the current status
-- UNION perfmon counters with dbm_monitor_data. They should be the same, but we don't trust them, so we check both.
INSERT INTO #SendStatus (ServerName, DbName, UnsentLogKb)
SELECT ar.replica_server_name AS ServerName,
        COALESCE(adc.database_name, DB_NAME(drs.database_id)) AS DbName,
        drs.log_send_queue_size AS UnsentLogKb
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
LEFT JOIN sys.availability_databases_cluster AS adc
    ON adc.group_id = drs.group_id AND adc.group_database_id = drs.group_database_id
WHERE drs.log_send_queue_size IS NOT NULL
  AND COALESCE(adc.database_name, DB_NAME(drs.database_id)) IS NOT NULL
UNION
SELECT @@SERVERNAME,
        LTRIM(RTRIM(instance_name)) as DbName, 
        cntr_value AS UnsentLogKb
FROM sys.[dm_os_performance_counters]  
WHERE object_name LIKE N'%:Database Replica'
AND counter_name  = 'Log Send Queue';

INSERT INTO #Results (ServerName, AgName, DbName, UnsentLogKb, SynchState, AgHealth, SuspendReason, 
                      LastHardenedTime, LastRedoneTime, RedoEstSecCompletion, LastCommitTime, SortOrder, AgRole)
SELECT COALESCE(ag.ServerName, @@SERVERNAME) AS ServerName,
       COALESCE(ag.AgName,'') AS AgName,
       COALESCE(sync.DbName, ag.DbName) AS DbName,
       MAX(sync.UnsentLogKb) AS UnsentLogKb,
       COALESCE(ag.SynchState,'') AS SynchState,
       COALESCE(ag.AgHealth,'') AS AgHealth,
       COALESCE(ag.SuspendReason,'') AS SuspendReason,
       MAX(ag.LastHardenedTime),
       MAX(ag.LastRedoneTime),
       MAX(ag.RedoEstSecCompletion),
       MAX(ag.LastCommitTime),
       CASE
            WHEN MAX(sync.UnsentLogKb) IS NULL THEN -1
            WHEN COALESCE(sync.DbName, ag.DbName) = '_Total' THEN 0
            WHEN MAX(sync.UnsentLogKb) > 1000 THEN 2
            WHEN COALESCE(ag.AgHealth,'') <> 'HEALTHY' THEN 3
            WHEN COALESCE(ag.SynchState,'') NOT IN ('SYNCHRONIZING','SYNCHRONIZED') THEN 4
            ELSE 5
       END AS SortOrder,
       MAX(ag.AgRole) AS AgRole
FROM #SendStatus AS sync
FULL OUTER JOIN #AgStatus AS ag ON sync.ServerName = ag.ServerName AND sync.DbName = ag.DbName
GROUP BY COALESCE(ag.ServerName,@@SERVERNAME),  COALESCE(ag.AgName,''), COALESCE(sync.DbName, ag.DbName),COALESCE(ag.SynchState,''), COALESCE(ag.AgHealth,''), 
          COALESCE(ag.SuspendReason,'') ;

UPDATE r
SET MinutesBehind = CASE WHEN r.LastCommitTime > p.LastCommitTime THEN 0
                         ELSE DATEDIFF(MINUTE, r.LastCommitTime, p.LastCommitTime) END
FROM #Results r
JOIN #AgStatus AS p ON p.AgName = r.AgName AND p.DbName = r.DbName AND p.IsPrimary = 1;



--Output results
-- Do filtering on the results here, rather than up above. 
-- There's not much data here, so no perf advantage to doing it sooner.
    IF NOT EXISTS (SELECT 1 FROM #Results)
        SELECT 'No AGs Exist' AS AgStatus;
    ELSE
        SELECT * 
        FROM #Results AS r
        WHERE (r.UnsentLogKb IS NULL OR r.UnsentLogKb >= @Threshold)
        AND r.DbName LIKE @DbName
        AND r.AgName LIKE @AgName
        AND r.DbName = CASE
                        WHEN @UnhealthyOnly = 0 
                            THEN r.DbName
                        WHEN EXISTS (SELECT 1 FROM #Results r2
                                    WHERE (r2.AgHealth <> 'HEALTHY' OR r2.UnsentLogKb IS NULL)
                                    AND r2.AgName = r.AgName
                                    AND r2.DbName = r.DbName)
                            THEN r.DbName
                      END
        ORDER BY SortOrder, r.UnsentLogKb DESC, ServerName, DbName;
GO
