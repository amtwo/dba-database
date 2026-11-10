CREATE OR ALTER PROCEDURE dbo.Repl_CreateSubscription
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
DECLARE @QuotedPubDbName nvarchar(258) = QUOTENAME(@PubDbName);

IF @QuotedPubDbName IS NULL OR DB_ID(@PubDbName) IS NULL
BEGIN
    RAISERROR ('The specified publication database is invalid or unavailable.', 16, 1);
    RETURN -1;
END;

IF DATALENGTH(@PublicationName) > 256
    OR DATALENGTH(@Subscriber) > 256
    OR DATALENGTH(@SubscriberDbName) > 256
BEGIN
    RAISERROR ('Publication, subscriber, and subscriber database names must be 128 characters or fewer.', 16, 1);
    RETURN -1;
END;

--Add the Subscriber
SET @sql = N'USE ' + @QuotedPubDbName + N';
EXEC sys.sp_addsubscription
    @publication = @PublicationName,
    @subscriber = @Subscriber,
    @destination_db = @SubscriberDbName,
    @subscription_type = N''Push'',
    @sync_type = N''automatic'',
    @article = N''all'',
    @update_mode = N''read only'',
    @subscriber_type = 0;';

IF @Debug = 0
BEGIN
    EXEC sys.sp_executesql @sql,
        N'@PublicationName nvarchar(256), @Subscriber nvarchar(256), @SubscriberDbName nvarchar(256)',
        @PublicationName = @PublicationName,
        @Subscriber = @Subscriber,
        @SubscriberDbName = @SubscriberDbName;
END
ELSE
BEGIN
    EXEC dbo.Debug_Print @DebugMessage = @sql;
    PRINT N'    @PublicationName: ' + @PublicationName;
    PRINT N'    @Subscriber: ' + @Subscriber;
    PRINT N'    @SubscriberDbName: ' + @SubscriberDbName;
END;

--Create the agent job
SET @sql = N'USE ' + @QuotedPubDbName + N';
EXEC sys.sp_addpushsubscription_agent
    @publication = @PublicationName,
    @subscriber = @Subscriber,
    @subscriber_db = @SubscriberDbName,
    @job_login = NULL,
    @job_password = NULL,
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
    @dts_package_location = N''Distributor'';';

IF @Debug = 0
BEGIN
    EXEC sys.sp_executesql @sql,
        N'@PublicationName nvarchar(256), @Subscriber nvarchar(256), @SubscriberDbName nvarchar(256)',
        @PublicationName = @PublicationName,
        @Subscriber = @Subscriber,
        @SubscriberDbName = @SubscriberDbName;
END
ELSE
BEGIN
    EXEC dbo.Debug_Print @DebugMessage = @sql;
    PRINT N'    @PublicationName: ' + @PublicationName;
    PRINT N'    @Subscriber: ' + @Subscriber;
    PRINT N'    @SubscriberDbName: ' + @SubscriberDbName;
END;
GO


