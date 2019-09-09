IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Repl_CreatePublication'))
    EXEC ('CREATE PROCEDURE dbo.Repl_CreatePublication AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Repl_CreatePublication
    @PubDbName nvarchar(256),
    @PublicationName nvarchar(256),
    @Debug bit = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20140101
    This procedure creates a publication using the specific defaults that I needed to use at the time.
    
PARAMETERS
* 
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDDD - Initials - Description of changes
**************************************************************************************************
    This code is licensed under the GNU GPL, as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2019 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;
---------------------
DECLARE @sql nvarchar(max);
DECLARE @Publisher nvarchar(256);
DECLARE @Distributor nvarchar(256);

--Figure out what server is the distributor. We'll need it later if this DB is in an AG
SELECT @Distributor = data_source
FROM master.sys.servers
where name = 'repl_distributor';

IF @Distributor IS NULL
BEGIN
    RAISERROR ('Server is not configured for replication. Configure a distributor and try again.',16,1)
    RETURN -1;
END;

--@Publisher is either the AG name or the instance name
--HACK - Wrapping this in an IF statement to support 2008
IF (object_id('sys.availability_groups') IS NOT NULL)
BEGIN
    SELECT @Publisher = ag.name
    FROM master.sys.databases d
    JOIN master.sys.availability_databases_cluster agd ON d.group_database_id = agd.group_database_id
    JOIN master.sys.availability_groups ag ON agd.group_id = ag.group_id
    WHERE d.name = @PubDbName
END;

SELECT @Publisher = COALESCE(@Publisher,@@SERVERNAME)

--Enable DB as replication publisher
SET @sql = 'USE [' + @PubDbName + ']' + CHAR(10) + CHAR(13);

SET @sql = @sql + N'EXEC sp_replicationdboption 
            @dbname = N''' + @PubDbName + N''', 
            @optname = N''publish'', 
            @value = N''true'';' + CHAR(10)+CHAR(13) ;

IF @Debug = 0
    EXEC sp_executesql @sql;
ELSE
    PRINT @sql;

-- Adding the transactional publication
SET @sql = 'USE [' + @PubDbName + '];' + CHAR(10) + CHAR(13);

SET @sql = @sql + N'EXEC sp_addpublication 
            @publication = N''' + @PublicationName + ''', 
            @description = N''Transactional publication of database ''''' + @PubDbName + ''''' from Publisher ''''' + @Publisher + '''''.'', 
            @sync_method = N''concurrent'', 
            @retention = 0, 
            @allow_push = N''true'', 
            @allow_pull = N''true'', 
            @allow_anonymous = N''false'', 
            @enabled_for_internet = N''false'', 
            @snapshot_in_defaultfolder = N''true'', 
            @compress_snapshot = N''false'', 
            @ftp_port = 21, 
            @allow_subscription_copy = N''false'', 
            @add_to_active_directory = N''false'', 
            @repl_freq = N''continuous'', 
            @status = N''active'', 
            @independent_agent = N''true'', 
            @immediate_sync = N''false'', 
            @allow_sync_tran = N''false'', 
            @allow_queued_tran = N''false'', 
            @allow_dts = N''false'', 
            @replicate_ddl = 1,
            @allow_initialize_from_backup = N''false'', 
            @enabled_for_p2p = N''false'', 
            @enabled_for_het_sub = N''false'';' + CHAR(10)+CHAR(13) ;

IF @Debug = 0
    EXEC sp_executesql @sql;
ELSE
    PRINT @sql;


-- Set snapshot agent to run on a schedule (hourly) to make sure new/changed articles 
SET @sql = 'USE [' + @PubDbName + ']' + CHAR(10) + CHAR(13);

SET @sql = @sql + 'exec sp_addpublication_snapshot 
            @publication = N''' + @PublicationName + ''', 
            @frequency_type = 4, 
            @frequency_interval = 1, 
            @frequency_relative_interval = 1, 
            @frequency_recurrence_factor = 0, 
            @frequency_subday = 8, 
            @frequency_subday_interval = 1, 
            @active_start_time_of_day = 0, 
            @active_end_time_of_day = 235959, 
            @active_start_date = 0, 
            @active_end_date = 0, 
            @job_login = null, 
            @job_password = null, 
            @publisher_security_mode = 1;' + CHAR(10)+CHAR(13) ;

IF @Debug = 0
    EXEC sp_executesql @sql;
ELSE
    PRINT @sql;


--If DB is in an AG, update distributor to know that
IF @Publisher <> @@SERVERNAME
BEGIN
    SET @sql = 'EXEC OPENDATASOURCE(''SQLNCLI'',''Data Source=' + @Distributor + ';Integrated Security=SSPI'').distribution.sys.sp_redirect_publisher 
            @original_publisher = ''' + @@SERVERNAME + ''',
            @publisher_db = ''' + @PubDbName + ''',
        @redirected_publisher = ''' + @Publisher + ''';' + CHAR(10)+CHAR(13) ;
    IF @Debug = 0
        EXEC sp_executesql @sql;
    ELSE
        PRINT @sql;
END;
GO


