IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Check_AgLatency'))
    EXEC ('CREATE PROCEDURE dbo.Check_AgLatency AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Check_AgLatency 
	@Threshold int = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20140409
       This Alert checks AG latency (unsent logs) and emails an alert. 
       Latency is based on the worst reported condition from both DMVs & perfmon.

PARAMETERS
* @Threshold - Default 5000 - Size in KB of the unsent log 
EXAMPLES:
*
**************************************************************************************************
MODIFICATIONS:
    20140804 - Start tracking Hardened LSN from DMV each time sproc runs. 
    20150107 - Add calculation for "minutes behind" to show how far behind primary a DB is
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
    SortOrder int
    );


-- Grab the current status from DMVs for mirroring & AGs
INSERT INTO #AgStatus (RunDate, ServerName, AgName, DbName, AgRole, SynchState, AgHealth, SuspendReason, 
                      SynchHardenedLSN, LastHardenedTime, LastRedoneTime, RedoEstSecCompletion,LastCommitTime)
    SELECT GETDATE() AS RunDate, 
           rcs.replica_server_name AS ServerName, 
           ag.Name                        COLLATE SQL_Latin1_General_CP1_CI_AS AS AgName,
           db_name(ds.database_id) AS DbName, 
           rs.role_desc                   COLLATE SQL_Latin1_General_CP1_CI_AS AS AgRole,
           ds.synchronization_state_desc  COLLATE SQL_Latin1_General_CP1_CI_AS AS SynchState, 
           ds.synchronization_health_desc COLLATE SQL_Latin1_General_CP1_CI_AS AS AgHealth, 
           ds. suspend_reason_desc        COLLATE SQL_Latin1_General_CP1_CI_AS AS SuspendReason, 
           ds.last_hardened_lsn  AS SynchHardenedLSN,
		   ds.last_hardened_time AS LastHardenedTime,
		   ds.last_redone_time AS LastRedoneTime,
		   CASE WHEN redo_rate = 0 THEN 0 ELSE ds.redo_queue_size/ds.redo_rate END AS RedoEstCompletion,
		   ds.last_commit_time AS LastCommitTime
    FROM sys.dm_hadr_database_replica_states ds
    JOIN sys.availability_groups_cluster ag ON ag.group_id = ds.group_id
    JOIN sys.dm_hadr_availability_replica_cluster_states rcs ON rcs.replica_id = ds.replica_id
    JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ds.replica_id;
	


--Lets make this easy, and create a temp table with the current status
-- UNION perfmon counters with dbm_monitor_data. They should be the same, but we don't trust them, so we check both.
INSERT INTO #SendStatus (ServerName, DbName, UnsentLogKb)
SELECT rcs.replica_server_name AS ServerName,
        db_name( drs.database_id) AS DbName, 
        COALESCE(drs.log_send_queue_size,99999) AS UnsentLogKb
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.dm_hadr_availability_replica_cluster_states rcs ON rcs.replica_id = drs.replica_id
WHERE drs.last_sent_time IS NOT NULL
UNION
SELECT @@SERVERNAME,
        LTRIM(RTRIM(instance_name)) as DbName, 
        cntr_value AS UnsentLogKb
FROM sys.[dm_os_performance_counters]  
WHERE object_name = 'SQLServer:Database Replica'
AND counter_name  = 'Log Send Queue';

INSERT INTO #Results (ServerName, AgName, DbName, UnsentLogKb, SynchState, AgHealth, SuspendReason, 
                      LastHardenedTime, LastRedoneTime, RedoEstSecCompletion, LastCommitTime, SortOrder)
SELECT COALESCE(ag.ServerName,'') AS ServerName,
       COALESCE(ag.AgName,'') AS AgName,
       RTRIM(sync.DbName) AS DbName,
       MAX(sync.UnsentLogKb) AS UnsentLogKb,
       COALESCE(ag.SynchState,'') AS SynchState,
	   COALESCE(ag.AgHealth,'') AS AgHealth,
	   COALESCE(ag.SuspendReason,'') AS SuspendReason,
	   MAX(LastHardenedTime),
	   MAX(LastRedoneTime),
	   MAX(RedoEstSecCompletion),
	   MAX(LastCommitTime),
       CASE
			WHEN RTRIM(sync.DbName) = '_Total' THEN 0
			WHEN MAX(sync.UnsentLogKb) > '1000' THEN 2
			WHEN COALESCE(ag.AgHealth,'') <> 'HEALTHY' THEN 3
            WHEN COALESCE(ag.SynchState,'') NOT IN ('SYNCHRONIZING','SYNCHRONIZED') THEN 4
			ELSE 5
		END AS SortOrder
FROM #SendStatus AS sync
LEFT JOIN #AgStatus AS ag ON sync.ServerName = ag.ServerName AND sync.DbName = ag.DbName 
GROUP BY COALESCE(ag.ServerName,''),  COALESCE(ag.AgName,''), RTRIM(sync.DbName),COALESCE(ag.SynchState,''), COALESCE(ag.AgHealth,''), 
          COALESCE(ag.SuspendReason,'') ;

UPDATE r
SET MinutesBehind = DATEDIFF(mi,r2.LastCommitTime,r.LastCommitTime)
FROM #Results r
JOIN #Results r2 ON r2.AgName = r.AgName AND r2.DbName = r.DbName AND r2.LastHardenedTime IS NULL; --Primary



--Output results
    IF NOT EXISTS (SELECT 1 FROM #Results)
    	SELECT 'No AGs Exist' AS AgStatus;
    ELSE
    	SELECT * 
        FROM #Results 
        WHERE UnsentLogKb >= @Threshold
        ORDER BY SortOrder, UnsentLogKb DESC, ServerName, DbName;



GO


