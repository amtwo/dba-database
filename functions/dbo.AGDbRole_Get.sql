IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'FN' AND object_id = object_id('dbo.AGDbRole_Get'))
    EXEC ('CREATE FUNCTION dbo.AGDbRole_Get() RETURNS nvarchar(60) AS BEGIN RETURN ''This is a stub''; END')
GO


ALTER FUNCTION dbo.AGDbRole_Get( @Name sysname)
RETURNS nvarchar(60)
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20140101
    If a database is in an AG, returns either primary or secondary status.
    If database is not in an AG, returns the DB's state (ONLINE, etc)
PARAMETERS:
    @Name - Name of a database or AG
EXAMPLES:
* 
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDD - 
**************************************************************************************************
    This code is free to download and use for personal, educational, and internal 
    corporate purposes, provided that this header is preserved. Redistribution or sale, 
    in whole or in part, is prohibited without the author's express written consent.
    ©2014-2017 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
BEGIN
    DECLARE @Role nvarchar(60);

    --AM2 Make this work for 2008 & older, too

    DECLARE @Sql nvarchar(max);

    IF CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(100)),2) as int) >= 11
    WITH hadr_role 
    AS (
        SELECT d.name  COLLATE SQL_Latin1_General_CP1_CI_AS AS Name, 
            d.state_desc  COLLATE SQL_Latin1_General_CP1_CI_AS AS StateDesc, 
            rs.role_desc  COLLATE SQL_Latin1_General_CP1_CI_AS AS RoleDesc
        FROM sys.databases d
        LEFT JOIN sys.dm_hadr_availability_replica_states rs
            ON rs.replica_id = d.replica_id AND rs.is_local = 1
        UNION ALL
        SELECT ag.name COLLATE SQL_Latin1_General_CP1_CI_AS, 
            rs.operational_state_desc COLLATE SQL_Latin1_General_CP1_CI_AS, 
            rs.role_desc  COLLATE SQL_Latin1_General_CP1_CI_AS
        FROM sys.availability_groups ag
        LEFT JOIN sys.dm_hadr_availability_replica_states rs
            ON rs.group_id = ag.group_id AND rs.is_local = 1
    )
    SELECT @Role = COALESCE(RoleDesc, StateDesc)
    FROM hadr_role
    WHERE Name = @Name;
    ELSE
        SELECT @Role = d.state_desc FROM sys.databases d WHERE d.name = @Name;

    RETURN @Role;
END
GO


