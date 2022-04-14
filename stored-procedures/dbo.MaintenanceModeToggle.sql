CREATE OR ALTER PROC dbo.MaintenanceModeToggle (
@Bit BIT, 
@DatabaseName NVARCHAR(128) = NULL, 
@AvailabilityGroup NVARCHAR(128) = NULL, 
@ServerName NVARCHAR(128) = NULL
)
AS
/*************************************************************************************************
AUTHOR: Patrick hurst
CREATED: 20220414
       
PARAMETERS
* @Bit - maintenance mode on (1) or off (0)
  @DatabaseName (NULL/optional) the name of the single database to toggle
  @AvailabilityGroup (NULL/optional) the name of the availability group to toggle all databases
  @ServerName (NULL/optional) the name of the server to toggle all databases
**************************************************************************************************
MODIFICATIONS:
       YYYYMMDDD - Initials - Description of changes
**************************************************************************************************

*************************************************************************************************/
BEGIN
 IF @bit = 1
 BEGIN
  INSERT INTO dbo.MaintenanceModeDatabases 
  SELECT d.name, SYSTEM_USER, GETUTCDATE()
    FROM master.sys.databases d
  	LEFT OUTER JOIN sys.dm_hadr_cached_database_replica_states rs
  	  ON d.name = rs.ag_db_name
  	  AND rs.is_local = 1
	LEFT OUTER JOIN MaintenanceModeDatabases mmd
	  ON d.name = mmd.DatabaseName 
   WHERE ((
              (@databaseName IS NULL or @databaseName = d.name)
  		AND (@availabilityGroup IS NULL OR @availabilityGroup = rs.ag_name)
  		AND @ServerName IS NULL
  	   )
     OR (@serverName IS NOT NULL))
	AND mmd.DatabaseName IS NULL;
 END;
 IF @bit = 0
 BEGIN
  DELETE mmd
    FROM dbo.MaintenanceModeDatabases mmd
  	LEFT OUTER JOIN sys.dm_hadr_cached_database_replica_states rs
  	  ON mmd.DatabaseName = rs.ag_db_name
  	  AND rs.is_local = 1
   WHERE (
              (@databaseName IS NULL or @databaseName = mmd.DatabaseName)
  		AND (@availabilityGroup IS NULL OR @availabilityGroup = rs.ag_name)
  		AND @ServerName IS NULL
  	   )
     OR (@serverName IS NOT NULL);
 END;
END;
GO


