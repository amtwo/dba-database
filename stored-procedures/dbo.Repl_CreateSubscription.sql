IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Repl_CreateSubscription'))
    EXEC ('CREATE PROCEDURE dbo.Repl_CreateSubscription AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Repl_CreateSubscription
    @PubDbName nvarchar(256),
    @PublicationName nvarchar(256),
    @Subscriber nvarchar(256),
    @SubscriberDbName nvarchar(256),
    @Debug bit = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20140101
    This procedure creates a push subscription for a given publication.
    
PARAMETERS
* 
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDDD - Initials - Description of changes
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;
---------------------
DECLARE @sql nvarchar(max);

--Add the Subscriber
SET @sql = 'USE [' + @PubDbName + ']' + CHAR(10) + CHAR(13);

SET @sql = @sql + 'EXEC sp_addsubscription 
            @publication = N''' + @PublicationName + ''', 
            @subscriber = N''' + @Subscriber + ''', 
            @destination_db = N''' + @SubscriberDbName + ''', 
            @subscription_type = N''Push'', 
            @sync_type = N''automatic'', 
            @article = N''all'', 
            @update_mode = N''read only'', 
            @subscriber_type = 0;' + CHAR(10)+CHAR(13) ;

IF @Debug = 0
    EXEC sp_executesql @sql;
ELSE
    PRINT @sql;

--Create the agent job
SET @sql = 'USE [' + @PubDbName + ']' + CHAR(10) + CHAR(13);

SET @sql = @sql + 'EXEC sp_addpushsubscription_agent 
            @publication = N''' + @PublicationName + ''', 
            @subscriber = N''' + @Subscriber + ''', 
            @subscriber_db = N''' + @SubscriberDbName + ''', 
            @job_login = null, 
            @job_password = null, 
            @subscriber_security_mode = 1, 
            @frequency_type = 64, 
            @frequency_interval = 0, 
            @frequency_relative_interval = 0, 
            @frequency_recurrence_factor = 0, 
            @frequency_subday = 0, 
            @frequency_subday_interval = 0, 
            @active_start_time_of_day = 0, 
            @active_end_time_of_day = 235959, 
            @active_start_date = 20150227, 
            @active_end_date = 99991231, 
            @enabled_for_syncmgr = N''False'', 
            @dts_package_location = N''Distributor'';'

IF @Debug = 0
    EXEC sp_executesql @sql;
ELSE
    PRINT @sql;
GO


