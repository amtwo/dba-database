CREATE OR ALTER PROCEDURE dbo.Set_AGReadOnlyRouting
    @Action               varchar(10),
    @AGNamePattern        nvarchar(128)   = N'%',
    @ModifyReplicaPattern nvarchar(128)   = N'%',
    @RoutingListPattern   nvarchar(max)   = NULL,
    @RoutingListCSV       nvarchar(max)   = NULL,
    @Debug                bit             = 0
AS

SET NOCOUNT ON;

--
--
-- Validate inputs! 
--
--
IF (@Action NOT IN ('DISABLE','ENABLE') )
BEGIN
    -- Did not specify a valid Action
    RAISERROR ('@Action must be specified as either "ENABLE" or "DISABLE".',16,1)
    RETURN;
END;

IF (@Action = 'DISABLE'
    AND COALESCE(@RoutingListCSV,@RoutingListPattern) IS NOT NULL)
BEGIN
    -- Disable will reset routing list to NONE. Not allowed to specify a routing list on Disable action
    RAISERROR ('For "DISABLE" @Action, both @RoutingListCSV and @RoutingListPattern must be NULL.',16,1)
    RETURN;
END;

IF (@Action = 'ENABLE'
    AND @RoutingListCSV IS NOT NULL 
    AND @RoutingListPattern IS NOT NULL)
BEGIN
    -- Enable routing with BOTH a CSV & Pattern for ROR list is not allowed
    RAISERROR ('For "ENABLE" @Action, specify a value for either @RoutingListCSV or @RoutingListPattern. The unused parameter must be NULL. Providing both is not allowed.',16,1)
    RETURN;
END;

IF (@Action = 'ENABLE'
    AND @RoutingListCSV IS NULL 
    AND @RoutingListPattern IS NULL)
BEGIN
    -- Enable routing with NEITHER a CSV & Pattern for ROR list is not allowed
    RAISERROR ('For "ENABLE" @Action, specify a value for either @RoutingListCSV or @RoutingListPattern. The unused parameter must be NULL. Providing neither is not allowed.',16,1)
    RETURN;
END;

--
--
-- Vars go here 
--
--
DECLARE @AgList TABLE (
                    GroupId     uniqueidentifier,
                    AgName      nvarchar(256)
                    );
DECLARE @RorList TABLE (
                    GroupId     uniqueidentifier,
                    ReplicaId   uniqueidentifier,
                    ReplicaName nvarchar(256),
                    RoutingList nvarchar(max)
                    );
DECLARE @sql nvarchar(max) = N'USE [master];' + CHAR(10);

--
--
-- OK, now do stuff
--
--


INSERT INTO @AgList (GroupId, AgName)
SELECT  ag.group_id,
        ag.name
FROM sys.availability_groups AS ag
JOIN sys.dm_hadr_availability_group_states AS ags ON ag.group_id = ags.group_id
WHERE ags.primary_replica = @@SERVERNAME
AND ag.is_distributed = 0
AND ag.name LIKE @AgNamePattern;

IF @Action = 'DISABLE'
BEGIN
    SELECT  @sql +=
            N'ALTER AVAILABILITY GROUP ' + QUOTENAME(ag.AgName) + CHAR(10) + 
            N'  MODIFY REPLICA ON ' + QUOTENAME(rcs.replica_server_name, NCHAR(39) ) + CHAR(10) +
            N'  WITH (PRIMARY_ROLE(READ_ONLY_ROUTING_LIST = ( NONE ))); ' + CHAR(10)
    FROM @AgList AS ag
    JOIN sys.dm_hadr_availability_replica_cluster_states AS rcs ON rcs.group_id = ag.GroupId
END;


IF @Action = 'ENABLE'
BEGIN
    --Sorting out the Read-Only-Routing (ROR) lists is the hard part.
    INSERT INTO @RorList (GroupId, ReplicaId, ReplicaName, RoutingList)
    SELECT ar.group_id,
            ar.replica_id,
            ar.replica_server_name,
            RoutingList = STRING_AGG('N''' + ror.replica_server_name + '''',',') WITHIN GROUP (ORDER BY IIF(ror.replica_server_name = ar.replica_server_name, 9, 0), ar.replica_server_name)
    FROM sys.availability_replicas AS ar
    JOIN sys.availability_replicas AS ror ON ror.group_id = ar.group_id
    WHERE ar.replica_server_name LIKE @ModifyReplicaPattern
    AND ror.replica_server_name LIKE @RoutingListPattern
    AND @RoutingListCSV IS NULL
    AND ror.secondary_role_allow_connections IN (1,2)
    GROUP BY ar.group_id, ar.replica_id, ar.replica_server_name
    UNION ALL
    SELECT  ar.group_id,
            ar.replica_id,
            ar.replica_server_name,
            STRING_AGG('N''' + ror.replica_server_name + '''',',') WITHIN GROUP (ORDER BY l.sort)
    FROM sys.availability_replicas AS ar
    JOIN sys.availability_replicas AS ror ON ror.group_id = ar.group_id
    JOIN (SELECT Sort = csv.ID,
                    ReplicaName = csv.Value
            FROM dbo.fn_split(@RoutingListCSV,N',') AS csv) AS l ON l.ReplicaName = ror.replica_server_name
    WHERE @RoutingListPattern IS NULL
    AND ror.secondary_role_allow_connections IN (1,2)
    GROUP BY ar.group_id, ar.replica_id, ar.replica_server_name
    
    --Now generate the actual ALTER
    SELECT  @sql +=
                N'ALTER AVAILABILITY GROUP ' + QUOTENAME(ag.AgName) + CHAR(10) + 
                N'  MODIFY REPLICA ON ' + QUOTENAME(rl.ReplicaName, NCHAR(39) ) + CHAR(10) +
                N'  WITH (PRIMARY_ROLE(READ_ONLY_ROUTING_LIST = (' + rl.RoutingList + N'))); ' + CHAR(10)
    FROM @AgList AS ag
    JOIN @RorList AS rl ON rl.GroupId = ag.GroupId
END;

IF @Debug = 0
  BEGIN
    EXEC sys.sp_executesql @stmt = @sql;
  END
ELSE
  BEGIN
    PRINT @sql;
  END;
GO
