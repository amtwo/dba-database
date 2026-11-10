CREATE OR ALTER PROCEDURE dbo.Alert_Blocking
    @BlockingDurationThreshold smallint = 60,
    @BlockedSessionThreshold smallint = NULL,
    @EmailRecipients varchar(max) = 'you@example.com',
    @EmailThreshold smallint = 10,
    @Debug tinyint = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20141218
    This procedure checks for blocking exceeding a duration of @BlockingDurationThreshold.
    Log leading blockers with email attempt status, or record HTML debug output.
    @Debug parameter controls whether to email blocking to @EmailRecipients or to output resultset.
    @EmailThreshold throttles queued email so that the server only submits an email every N minutes.
    Set @EmailThreshold to 0 to disable email throttling; NULL and negative values are invalid.
    An in-flight send claim expires after five minutes if its session does not update the status.

PARAMETERS
* @BlockingDurationThreshold - seconds - Alters on blocked sessions that have been waiting longer than this many seconds.
* @BlockedSessionThreshold - Alert on blocking only when the number of blocked sessions is this number of higher.
* @EmailRecipients   - delimited list of email addresses. Used for sending email alert.
* @EmailThreshold    - minutes - Only send an email every this many minutes; 0 disables throttling; NULL and negative values are invalid.
* @Debug             - Supress sending email & output a resultset instead
                          0 = Send email
                          1 = Suppress sending emails and suppress logging to dbo.Monitor_Blocking
                                Output as result sets instead.
                          2 = Suppress sending emails, but still log to dbo.Monitor_Blocking
                                Output HTML text instead.
**************************************************************************************************
MODIFICATIONS:
    20141222 - AM2 - Parse out the Hex jobid in ProgramName & turn into the Job Name.
    20141229 - AM2 - Parse out current SqlStatement from the complete SqlText.
                   - Start including SqlStatement in the email instead of SqlText
             - I now have 3 different answers to "What is the current SQL?"
               1) SqlText - This is the full output from sys.dm_exec_sql_text(). 
                          - If a procedure is running, this will be the CREATE PROCEDURE statement.
               2) SqlStatement - Uses Statement offset values to determine specific line from SqlText
                          - If a procedure is running, this is the specific statement within that proc
               3) InputBuffer - This is the output from DBCC INPUTBUFFER
                          - If a procedure is running, this is the EXEC statement
    20171208 - AM2 - Add some functionality so that I can alert on number of sessions blocked.
    20171210 - AM2 - Add Debug Mode = 2 to return the Email Body as a chunk of HTML instead of emailing it.
    20261101 - Cody - Hardened blocking alert validation and metadata handling.
    20261101 - Cody - Decode TAB wait resources to object and index names.
    20261101 - Cody - Use shared wait-resource and SQL Agent job ID functions and encode HTML data.
    20261101 - Cody - Serialize alert submissions and record queue/error status for retry safety.

**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;
--READ UNCOMMITTED, since we're dealing with blocking, we don't want to make things worse.
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

---Sure, it would work if you supplied both, but the ANDing of those gets confusing to people, so easier to just do this.
IF ((@BlockingDurationThreshold IS NOT NULL AND @BlockedSessionThreshold IS NOT NULL)
    OR COALESCE(@BlockingDurationThreshold,@BlockedSessionThreshold) IS NULL)
BEGIN
    RAISERROR('Must supply either @BlockingDurationThreshold or @BlockedSessionThreshold (but not both).',16,1);
    RETURN;
END;

IF @EmailThreshold IS NULL OR @EmailThreshold < 0
BEGIN
    RAISERROR('@EmailThreshold must be 0 or greater.',16,1);
    RETURN;
END;


DECLARE @Id                           int              = 1,
        @Spid                         int              = 0,
        @WaitResource                 nvarchar(256),
        @ResourceType                 varchar(8),
        @DbName                       nvarchar(256),
        @ObjectId                     int,
        @SchemaName                   sysname,
        @ObjectName                   nvarchar(256),
        @IndexName                    nvarchar(256),
        @IndexId                      int,
        @HobtId                       bigint,
        @FileId                       int,
        @FileName                     sysname,
        @PageId                       bigint,
        @SlotId                       int,
        @BlockedRowId                 int,
        @Sql                          nvarchar(max),
        @EmailFromDomain              varchar(max),
        @EmailFrom                    varchar(max),
        @EmailBody                    nvarchar(max),
        @EmailSubject                 nvarchar(255),
        @AlertId                      uniqueidentifier = NEWID(),
        @EmailAttemptDateTime         datetime2(3),
        @EmailQueuedDateTime          datetime2(3),
        @EmailError                   nvarchar(4000),
        @DatabaseMailItemId           int,
        @DatabaseMailReturnCode       int,
        @ApplicationLockResult        int,
        @ApplicationLockReleaseResult int,
        @ApplicationLockHeld          bit              = 0;

DECLARE @AlertLogRows table (
    LogDateTime datetime2(0) NOT NULL,
    LogId int NOT NULL PRIMARY KEY
);

CREATE TABLE #Blocked (
    ID int identity(1,1) PRIMARY KEY,
    WaitingSpid smallint,
    BlockingSpid smallint,
    LeadingBlocker smallint,
    BlockingChain nvarchar(4000),
    DbName sysname,
    HostName nvarchar(128),
    ProgramName nvarchar(128),
    LoginName nvarchar(128),
    LoginTime datetime2(3),
    LastRequestStart datetime2(3),
    LastRequestEnd datetime2(3),
    TransactionCnt int,
    Command nvarchar(32),
    WaitTime int,
    WaitResource nvarchar(256),
    WaitDescription nvarchar(1000),
    SqlText nvarchar(max),
    SqlStatement nvarchar(max),
    InputBuffer nvarchar(4000),
    SessionInfo nvarchar(max),
    );

CREATE TABLE #InputBuffer (
    EventType nvarchar(30),
    Params smallint,
    EventInfo nvarchar(4000)
    );

CREATE TABLE #LeadingBlocker (
    Id int identity(1,1) PRIMARY KEY,
    LeadingBlocker smallint,
    BlockedSpidCount int,
    DbName sysname,
    HostName nvarchar(128),
    ProgramName nvarchar(128),
    LoginName nvarchar(128),
    LoginTime datetime2(3),
    LastRequestStart datetime2(3),
    LastRequestEnd datetime2(3),
    TransactionCnt int,
    Command nvarchar(32),
    WaitTime int,
    WaitResource nvarchar(256),
    WaitDescription nvarchar(1000),
    SqlText nvarchar(max),
    SqlStatement nvarchar(max),
    InputBuffer nvarchar(4000),
    SessionInfo nvarchar(max),
    );


--Grab all sessions involved in Blocking (both blockers & waiters)

INSERT INTO #Blocked (WaitingSpid, BlockingSpid, DbName, HostName, ProgramName, LoginName, LoginTime, LastRequestStart, 
                    LastRequestEnd, TransactionCnt, Command, WaitTime, WaitResource, SqlText, SqlStatement)
-- WAITERS
SELECT s.session_id AS WaitingSpid, 
       r.blocking_session_id AS BlockingSpid,
       db_name(r.database_id) AS DbName,
       s.host_name AS HostName,
       s.program_name AS ProgramName,
       s.login_name AS LoginName,
       s.login_time AS LoginTime,
       s.last_request_start_time AS LastRequestStart,
       s.last_request_end_time AS LastRequestEnd,
       -- Need to use sysprocesses for now until we're fully on 2012/2014
       (SELECT TOP 1 sp.open_tran FROM master.sys.sysprocesses sp WHERE sp.spid = s.session_id) AS TransactionCnt,
       --s.open_transaction_count AS TransactionCnt,
       r.command AS Command,
       r.wait_time AS WaitTime,
       r.wait_resource AS WaitResource,
       COALESCE(t.text,'') AS SqlText,
       COALESCE(SUBSTRING(t.text, (r.statement_start_offset/2)+1, (
                (CASE r.statement_end_offset
                   WHEN -1 THEN DATALENGTH(t.text)
                   ELSE r.statement_end_offset
                 END - r.statement_start_offset)
              /2) + 1),'') AS SqlStatement
FROM sys.dm_exec_sessions s
INNER JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text (r.sql_handle) t
WHERE r.blocking_session_id <> 0                --Blocked
AND r.wait_time >= COALESCE(@BlockingDurationThreshold,0)*1000
UNION 
-- BLOCKERS
SELECT s.session_id AS WaitingSpid, 
       COALESCE(r.blocking_session_id,0) AS BlockingSpid,
       COALESCE(db_name(r.database_id),'') AS DbName,
       s.host_name AS HostName,
       s.program_name AS ProgramName,
       s.login_name AS LoginName,
       s.login_time AS LoginTime,
       s.last_request_start_time AS LastRequestStart,
       s.last_request_end_time AS LastRequestEnd,
       -- Need to use sysprocesses for now until we're fully on 2012/2014
       (SELECT TOP 1 sp.open_tran FROM master.sys.sysprocesses sp WHERE sp.spid = s.session_id) AS TransactionCnt,
       --s.open_transaction_count AS TransactionCnt,
       COALESCE(r.command,'') AS Command, 
       COALESCE(r.wait_time,'') AS WaitTime,
       COALESCE(r.wait_resource,'') AS WaitResource,
       COALESCE(t.text,'') AS SqlText,
       COALESCE(SUBSTRING(t.text, (r.statement_start_offset/2)+1, (
                (CASE r.statement_end_offset
                   WHEN -1 THEN DATALENGTH(t.text)
                   ELSE r.statement_end_offset
                 END - r.statement_start_offset)
              /2) + 1),'') AS SqlStatement
FROM sys.dm_exec_sessions s
LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text (r.sql_handle) t
WHERE s.session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests ) --Blockers
AND COALESCE(r.blocking_session_id,0) = 0;                  --Not blocked


-- Grab the input buffer for all sessions, too.
WHILE EXISTS (SELECT 1 FROM #Blocked WHERE InputBuffer IS NULL)
BEGIN
    TRUNCATE TABLE #InputBuffer;
    
    SELECT TOP 1 @Spid = WaitingSpid, @ID = ID
    FROM #Blocked
    WHERE InputBuffer IS NULL;

    SET @Sql = 'DBCC INPUTBUFFER (' + CAST(@Spid AS varchar(10)) + ');';

    BEGIN TRY
        INSERT INTO #InputBuffer
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        PRINT 'InputBuffer Failed';
    END CATCH
    
    --SELECT @id, @Spid, COALESCE((SELECT TOP 1 EventInfo FROM #InputBuffer),'')
    --EXEC sp_executesql @sql;

    UPDATE b
    SET InputBuffer = COALESCE((SELECT TOP 1 EventInfo FROM #InputBuffer),'')
    FROM #Blocked b
    WHERE ID = @Id;
END;

--Convert Hex job IDs for SQL Agent jobs to names.
UPDATE b
SET ProgramName = LEFT(REPLACE(b.ProgramName, jobId.JobIdHex, jobId.JobName), 128)
FROM #Blocked b
CROSS APPLY dbo.SqlAgentJobId_Get(b.ProgramName) jobId
WHERE jobId.JobIdHex IS NOT NULL;

--Decode wait resources.
-- Keep each description tied to its blocked row; one session may have multiple wait resources.
DECLARE wait_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT b.ID, b.WaitingSpid, resource.RawResource, resource.ResourceType, resource.DatabaseName,
           resource.ObjectId, resource.SchemaName, resource.ObjectName, resource.IndexId, resource.HobtId,
           resource.FileId, resource.FileName, resource.PageId, resource.SlotId
    FROM #Blocked b
    CROSS APPLY dbo.WaitResource_Get(b.WaitResource) resource
    WHERE b.WaitResource <> '';

OPEN wait_cur;
FETCH NEXT FROM wait_cur INTO @BlockedRowId, @Spid, @WaitResource, @ResourceType, @DbName,
    @ObjectId, @SchemaName, @ObjectName, @IndexId, @HobtId, @FileId, @FileName, @PageId, @SlotId;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @IndexName = NULL;

    IF @ResourceType = 'KEY'
    BEGIN
        SET @ObjectName = NULL;
        SET @Sql = N'SELECT @ObjectName = SCHEMA_NAME(o.schema_id) + N''.'' + o.name, @IndexName = i.name ' +
            N'FROM ' + QUOTENAME(@DbName) + N'.sys.partitions p ' +
            N'JOIN ' + QUOTENAME(@DbName) + N'.sys.objects o ON p.object_id = o.object_id ' +
            N'JOIN ' + QUOTENAME(@DbName) + N'.sys.indexes i ON p.object_id = i.object_id AND p.index_id = i.index_id ' +
            N'WHERE p.hobt_id = @HobtId';
        EXEC sys.sp_executesql @Sql,
            N'@HobtId bigint, @ObjectName nvarchar(256) OUTPUT, @IndexName nvarchar(256) OUTPUT',
            @HobtId = @HobtId, @ObjectName = @ObjectName OUTPUT, @IndexName = @IndexName OUTPUT;

        UPDATE b
        SET WaitDescription = COALESCE('KEY WAIT: ' + @DbName + '.' + @ObjectName + ' (' + COALESCE(@IndexName, '') + ')', @WaitResource)
        FROM #Blocked b
        WHERE b.ID = @BlockedRowId;
    END;
    ELSE IF @ResourceType = 'OBJECT'
    BEGIN
        UPDATE b
        SET WaitDescription = COALESCE('OBJECT WAIT: ' + @DbName + '.' + @SchemaName + '.' + @ObjectName, @WaitResource)
        FROM #Blocked b
        WHERE b.ID = @BlockedRowId;
    END;
    ELSE IF @ResourceType = 'TAB'
    BEGIN
        SET @Sql = N'SELECT @IndexName = i.name FROM ' + QUOTENAME(@DbName) +
            N'.sys.indexes i WHERE i.object_id = @ObjectId AND i.index_id = @IndexId';
        EXEC sys.sp_executesql @Sql,
            N'@ObjectId int, @IndexId int, @IndexName nvarchar(256) OUTPUT',
            @ObjectId = @ObjectId, @IndexId = @IndexId, @IndexName = @IndexName OUTPUT;

        UPDATE b
        SET WaitDescription = COALESCE('TAB WAIT: ' + @DbName + '.' + @SchemaName + '.' + @ObjectName +
            CASE WHEN @IndexId IS NULL OR @IndexId = 0 THEN ''
                 WHEN @IndexName IS NOT NULL THEN ' (Index: ' + @IndexName + ')'
                 ELSE ' (Index ID: ' + CONVERT(varchar(11), @IndexId) + ')'
            END, @WaitResource)
        FROM #Blocked b
        WHERE b.ID = @BlockedRowId;
    END;
    ELSE IF @ResourceType IN ('PAGE', 'RID')
    BEGIN
        IF @ResourceType = 'RID'
        BEGIN
            UPDATE b
            SET WaitDescription = COALESCE('ROW WAIT: ' + @DbName + ' File: ' + @FileName +
                ' Page_id/Slot: ' + CONVERT(varchar(20), @PageId) + ':' + CONVERT(varchar(11), @SlotId), @WaitResource)
            FROM #Blocked b
            WHERE b.ID = @BlockedRowId;
        END;
        ELSE
        BEGIN
            UPDATE b
            SET WaitDescription = COALESCE('PAGE WAIT: ' + @DbName + ' File: ' + @FileName +
                ' Page_id: ' + CONVERT(varchar(20), @PageId), @WaitResource)
            FROM #Blocked b
            WHERE b.ID = @BlockedRowId;
        END;
    END;

    FETCH NEXT FROM wait_cur INTO @BlockedRowId, @Spid, @WaitResource, @ResourceType, @DbName,
        @ObjectId, @SchemaName, @ObjectName, @IndexId, @HobtId, @FileId, @FileName, @PageId, @SlotId;
END;
CLOSE wait_cur;
DEALLOCATE wait_cur;


--Move the LEADING blockers out to their own table.
INSERT INTO #LeadingBlocker (LeadingBlocker, DbName, HostName, ProgramName, LoginName, LoginTime, LastRequestStart, LastRequestEnd, 
                    TransactionCnt, Command, WaitTime, WaitResource, WaitDescription, SqlText, SqlStatement, InputBuffer)
SELECT WaitingSpid, DbName, HostName, ProgramName, LoginName, LoginTime, LastRequestStart, LastRequestEnd, 
                    TransactionCnt, Command, WaitTime, WaitResource, WaitDescription, SqlText, SqlStatement, InputBuffer
FROM #Blocked b
WHERE BlockingSpid = 0
AND EXISTS (SELECT 1 FROM #Blocked b1 WHERE b1.BlockingSpid = b.WaitingSpid);

DELETE FROM #Blocked WHERE BlockingSpid = 0;

-- Represent special negative blocker IDs as roots so their waiters remain in the report.
INSERT INTO #LeadingBlocker (LeadingBlocker, DbName, HostName, ProgramName, LoginName, Command)
SELECT DISTINCT b.BlockingSpid,
       'SYSTEM',
       'SQL Server',
       CASE b.BlockingSpid
           WHEN -2 THEN 'Orphaned distributed transaction'
           WHEN -3 THEN 'Deferred recovery transaction'
           WHEN -4 THEN 'Latch owner could not be determined'
           WHEN -5 THEN 'Asynchronous action'
           ELSE 'Unknown system blocker'
       END,
       'SYSTEM',
       'SYSTEM'
FROM #Blocked b
WHERE b.BlockingSpid < 0;

--Update #Blocked to include LeadingBlocker & BlockingChain
WITH BlockingChain AS (
    SELECT LeadingBlocker AS Spid, 
           CAST(0 AS smallint) AS Blocker,
           CAST(LeadingBlocker AS nvarchar(4000)) AS BlockingChain, 
           LeadingBlocker AS LeadingBlocker
    FROM #LeadingBlocker
    UNION ALL
    SELECT b.WaitingSpid AS Spid, 
           b.BlockingSpid AS Blocker,
           RIGHT((CAST(b.WaitingSpid AS nvarchar(10)) + N' ' + CHAR(187) + N' ' + bc.BlockingChain),4000) AS BlockingChain,
           bc.LeadingBlocker
    FROM #Blocked b
    JOIN BlockingChain bc ON bc.Spid = b.BlockingSpid
    )
UPDATE b
SET LeadingBlocker = bc.LeadingBlocker,
    BlockingChain = bc.BlockingChain
FROM #Blocked b
JOIN BlockingChain bc ON b.WaitingSpid = bc.Spid
-- Allow the full smallint session-ID range while retaining a guard against cycles.
OPTION (MAXRECURSION 32767);

-- Populate BlockedSpidCount for #LeadingBlocker
UPDATE lb
SET BlockedSpidCount = cnt.BlockedSpidCount
FROM #LeadingBlocker lb
JOIN (SELECT LeadingBlocker, COUNT(*) BlockedSpidCount FROM #Blocked GROUP BY LeadingBlocker) cnt 
        ON cnt.LeadingBlocker = lb.LeadingBlocker;


-- Populate SessionInfo column with HTML details for sending email
-- Since there's a bunch of logic here, code is more readable doing this separate than mashing it in with the rest of HTML email creation
UPDATE lb
SET SessionInfo = '<span style="font-weight:bold">Login = </span>' + dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(LoginName)) + '<br>' +
                  CASE WHEN TransactionCnt <> 0 
                    THEN '<span style="font-weight:bold">Transaction Count = </span>' + CAST(TransactionCnt AS nvarchar(10)) + '<br>' 
                    ELSE ''
                  END +
                  CASE WHEN WaitResource <> ''
                    THEN '<span style="font-weight:bold">Wait Resource = </span>' + dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(COALESCE(WaitDescription,WaitResource))) + '<br>'
                    ELSE ''
                  END +
                  '<span style="font-weight:bold">Host Name = </span>' + dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(HostName)) + '<br>' +
                  CASE WHEN DbName <> ''
                    THEN '<span style="font-weight:bold">DbName = </span>' + dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(DbName)) + '<br>'
                    ELSE ''
                  END +
                  '<span style="font-weight:bold">Last Request = </span>' + COALESCE(CONVERT(varchar(20),LastRequestStart,20),'N/A') + '<br>' +
                  '<span style="font-weight:bold">Program Name = </span>' + dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(ProgramName)) + '<br>'
FROM #LeadingBlocker lb;

UPDATE b
SET SessionInfo = '<span style="font-weight:bold">Login = </span>' + dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(LoginName)) + '<br>' +
                  '<span style="font-weight:bold">Host Name = </span>' + dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(HostName)) + '<br>' +
                  CASE WHEN TransactionCnt <> 0 
                    THEN '<span style="font-weight:bold">Transaction Count = </span>' + CAST(TransactionCnt AS nvarchar(10)) + '<br>' 
                    ELSE ''
                  END +
                  CASE WHEN WaitResource <> ''
                    THEN '<span style="font-weight:bold">Wait Resource = </span>' + dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(COALESCE(WaitDescription,WaitResource))) + '<br>'
                    ELSE ''
                  END +
                  '<span style="font-weight:bold">DbName = </span>' + dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(DbName)) + '<br>' +
                  '<span style="font-weight:bold">Last Request = </span>' + CONVERT(varchar(20),LastRequestStart,20) + '<br>' +
                  '<span style="font-weight:bold">Program Name = </span>' + dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(ProgramName)) + '<br>'
FROM #Blocked b;

--output results in debug mode:
IF @Debug = 1
BEGIN
    IF NOT EXISTS (SELECT 1 FROM #LeadingBlocker UNION SELECT 1 FROM #Blocked)
        SELECT 'No Blocking Detected' AS Blocking;
    ELSE
    BEGIN
        SELECT * FROM #LeadingBlocker 
        WHERE BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,BlockedSpidCount)
        ORDER BY LoginTime;
        --
        SELECT * FROM #Blocked b
        WHERE EXISTS (SELECT 1 FROM #LeadingBlocker lb 
                        WHERE lb.LeadingBlocker = b.LeadingBlocker
                        AND lb.BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,lb.BlockedSpidCount))
        ORDER BY b.WaitTime DESC;
    END;
END;

-- If no rows returned, nothing to do... just return
IF NOT EXISTS (SELECT 1 FROM #Blocked)
BEGIN
    RETURN (0);
END;

IF NOT EXISTS (SELECT 1 FROM #LeadingBlocker WHERE BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,BlockedSpidCount))
BEGIN
    RETURN (0);
END;

-- Logging & Email Only happens when @Debug = 0
IF @Debug IN (0,2) 
BEGIN
    --Email about blocking
    -- TBD: Possibly email users if they are the leading blocker as well (based on loginname)?

    -- Send Email WITH STYLE
    SELECT @EmailBody = dbo.EmailCSS_Get();

    --Build the body of the email

    --Leading Blockers
    SET @EmailBody = @EmailBody + N'<h2>Leading Blocker(s):</h2>' + CHAR(10) +
            N'<table><tr>' +
            N'<th>SPID</th>' +
            N'<th>Block Count</th>' +
            N'<th>Session Info</th>' +
            N'<th>SQL Statement</th>' +
            N'<th>Input Buffer</th>' +
            N'</tr>' +
            REPLACE(REPLACE(REPLACE(CAST(( SELECT
                    td = CAST(LeadingBlocker AS nvarchar(10)), '',
                    td = CAST(BlockedSpidCount AS nvarchar(10)), '',
                    td = dbo.XmlSafeText_Get(SessionInfo) ,'',
                    td = dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(LEFT(SqlStatement,300))), '',    --Truncate string, too long for email alert
                    td = dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(LEFT(InputBuffer,300))), ''      --Truncate string, too long for email alert
                    FROM #LeadingBlocker
                    WHERE BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,BlockedSpidCount)
                    ORDER BY LoginTime
                    FOR XML PATH ('tr'), ELEMENTS
                    ) AS nvarchar(max)), '&lt;', '<'), '&gt;', '>'), '&amp;', '&') +
            N'</table>';

    --Waiting/Blocked sessions
    SET @EmailBody = @EmailBody + N'<h2>Waiting/Blocked session(s):</h2>' + CHAR(10) +
            N'<table><tr>' +
            N'<th>SPID</th>' +
            N'<th>Blocking Chain</th>' +
            N'<th>Wait Time (sec)</th>' +
            N'<th>Session Info</th>' +
            N'<th>SQL Statement</th>' +
            N'<th>Input Buffer</th>' + 
            N'</tr>' +
            REPLACE(REPLACE(REPLACE(CAST(( SELECT
                    td = CAST(WaitingSpid AS nvarchar(10)), '',
                    td = dbo.XmlSafeText_Get(RIGHT(BlockingChain,18)), '',   -- We just want the leading blocker & a few spids leading up to that
                    td = CAST(WaitTime/1000 AS nvarchar(10)), '',
                    td = dbo.XmlSafeText_Get(SessionInfo) ,'',
                    td = dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(LEFT(SqlStatement,300))), '',    --Truncate string, too long for email alert
                    td = dbo.HtmlEncode_Get(dbo.XmlSafeText_Get(LEFT(InputBuffer,300))), ''      --Truncate string, too long for email alert
                    FROM #Blocked b
                    WHERE EXISTS (SELECT 1 FROM #LeadingBlocker lb 
                                WHERE lb.LeadingBlocker = b.LeadingBlocker
                                AND lb.BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,lb.BlockedSpidCount))
                    ORDER BY WaitTime desc
                    FOR XML PATH ('tr'), ELEMENTS
                    ) AS nvarchar(max)), '&lt;', '<'), '&gt;', '>'), '&amp;', '&') +
            N'</table>';
    
    SELECT @EmailBody = @EmailBody + '<hr>' + dbo.EmailServerInfo_Get();

    SELECT @EmailFromDomain = UnicodeValue
    FROM dbo.Config
    WHERE ConfigCode = 'EMAILALRTDOMAIN';

    IF LEFT(@EmailFromDomain ,1) <> '@'
    BEGIN
        SET @EmailFromDomain = '@' + @EmailFromDomain;
    END

    --In Debug Mode = 0, send the email
    IF (@Debug = 0)
    BEGIN
        SET @EmailSubject = 'ALERT: Blocking Detected';
        SET @EmailFrom = @@SERVERNAME + ' <' + REPLACE(@@SERVERNAME,'\','_') + @EmailFromDomain + '>';

        EXEC @ApplicationLockResult = sys.sp_getapplock
            @Resource = N'dbo.Alert_Blocking.EmailThrottle',
            @LockMode = 'Exclusive',
            @LockOwner = 'Session',
            @LockTimeout = 0;

        -- Another execution is already checking the throttle or creating its sending claim.
        IF @ApplicationLockResult = -1
            RETURN (0);

        IF @ApplicationLockResult < 0
        BEGIN
            RAISERROR('Could not acquire the blocking-alert application lock (return code %d).',16,1,@ApplicationLockResult);
            RETURN;
        END;

        SET @ApplicationLockHeld = 1;

        BEGIN TRY
            SET @EmailAttemptDateTime = SYSDATETIME();

            -- A fresh sending claim suppresses duplicates for five minutes, even when throttling is disabled.
            -- A queued email suppresses further alerts only for the configured throttle interval.
            IF EXISTS (
                    SELECT 1
                    FROM dbo.Monitor_Blocking
                    WHERE EmailStatus = 'sending'
                    AND EmailAttemptDateTime >= DATEADD(MINUTE,-5,@EmailAttemptDateTime)
                )
                OR (@EmailThreshold > 0 AND (
                    EXISTS (
                        SELECT 1
                        FROM dbo.Monitor_Blocking
                        WHERE EmailStatus = 'queued'
                        AND EmailQueuedDateTime >= DATEADD(MINUTE,-@EmailThreshold,@EmailAttemptDateTime)
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM dbo.Monitor_Blocking
                        WHERE EmailStatus = 'sending'
                        AND DatabaseMailItemId IS NOT NULL
                        AND EmailQueuedDateTime >= DATEADD(MINUTE,-@EmailThreshold,@EmailAttemptDateTime)
                    )
                ))
            BEGIN
                EXEC @ApplicationLockReleaseResult = sys.sp_releaseapplock
                    @Resource = N'dbo.Alert_Blocking.EmailThrottle',
                    @LockOwner = 'Session';

                IF @ApplicationLockReleaseResult < 0
                    RAISERROR('Could not release the blocking-alert application lock (return code %d).',16,1,@ApplicationLockReleaseResult);

                SET @ApplicationLockHeld = 0;
                RETURN (0);
            END;

            -- Claim the alert before submitting it so concurrent executions see the in-flight state.
            INSERT INTO dbo.Monitor_Blocking (AlertId, AlertRecipients, EmailAttemptDateTime, EmailStatus,
                        LeadingBlocker, DbName, HostName, ProgramName, LoginName, LoginTime, LastRequestStart,
                        LastRequestEnd, TransactionCnt, Command, WaitTime, WaitResource, SqlText, SqlStatement, BlockedSpidCount)
            OUTPUT inserted.LogDateTime, inserted.LogId INTO @AlertLogRows (LogDateTime, LogId)
            SELECT @AlertId, @EmailRecipients, @EmailAttemptDateTime, 'sending',
                   LeadingBlocker, DbName, HostName, ProgramName, LoginName, LoginTime, LastRequestStart,
                   LastRequestEnd, TransactionCnt, Command, WaitTime, WaitResource, SqlText, SqlStatement, BlockedSpidCount
            FROM #LeadingBlocker lb
            WHERE BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,BlockedSpidCount);

            -- The durable sending claim now suppresses other attempts; release the lock so a stale claim can expire.
            EXEC @ApplicationLockReleaseResult = sys.sp_releaseapplock
                @Resource = N'dbo.Alert_Blocking.EmailThrottle',
                @LockOwner = 'Session';

            IF @ApplicationLockReleaseResult < 0
                RAISERROR('Could not release the blocking-alert application lock (return code %d).',16,1,@ApplicationLockReleaseResult);

            SET @ApplicationLockHeld = 0;

            EXEC @DatabaseMailReturnCode = msdb.dbo.sp_send_dbmail
                @recipients = @EmailRecipients,
                @from_address = @EmailFrom,
                @subject = @EmailSubject,
                @body = @EmailBody,
                @body_format = 'HTML',
                @importance = 'High',
                @mailitem_id = @DatabaseMailItemId OUTPUT;

            IF COALESCE(@DatabaseMailReturnCode,-1) <> 0
            BEGIN
                SET @DatabaseMailReturnCode = COALESCE(@DatabaseMailReturnCode,-1);
                RAISERROR('Database Mail did not queue the blocking alert (return code %d).',16,1,@DatabaseMailReturnCode);
            END;

            IF @DatabaseMailItemId IS NULL
                RAISERROR('Database Mail returned success without a mail item ID.',16,1);

            SET @EmailQueuedDateTime = SYSDATETIME();

            UPDATE mb
            SET EmailStatus = 'queued',
                EmailQueuedDateTime = @EmailQueuedDateTime,
                DatabaseMailItemId = @DatabaseMailItemId,
                EmailError = NULL
            FROM dbo.Monitor_Blocking mb
            INNER JOIN @AlertLogRows r ON r.LogDateTime = mb.LogDateTime AND r.LogId = mb.LogId;
        END TRY
        BEGIN CATCH
            SET @EmailError = ERROR_MESSAGE();

            IF @DatabaseMailReturnCode = 0 AND @DatabaseMailItemId IS NOT NULL
            BEGIN
                -- Mail is already queued. Preserve that fact if updating its status initially failed.
                SET @EmailQueuedDateTime = COALESCE(@EmailQueuedDateTime,SYSDATETIME());

                BEGIN TRY
                    UPDATE mb
                    SET EmailStatus = 'queued',
                        EmailQueuedDateTime = @EmailQueuedDateTime,
                        DatabaseMailItemId = @DatabaseMailItemId,
                        EmailError = NULL
                    FROM dbo.Monitor_Blocking mb
                    INNER JOIN @AlertLogRows r ON r.LogDateTime = mb.LogDateTime AND r.LogId = mb.LogId;
                END TRY
                BEGIN CATCH
                    BEGIN TRY
                        UPDATE mb
                        SET EmailQueuedDateTime = @EmailQueuedDateTime,
                            DatabaseMailItemId = @DatabaseMailItemId
                        FROM dbo.Monitor_Blocking mb
                        INNER JOIN @AlertLogRows r ON r.LogDateTime = mb.LogDateTime AND r.LogId = mb.LogId;
                    END TRY
                    BEGIN CATCH
                        -- Keep the fresh sending claim when the already-queued mail cannot be recorded.
                    END CATCH;
                END CATCH;
            END;
            ELSE
            BEGIN
                BEGIN TRY
                    UPDATE mb
                    SET EmailStatus = 'error',
                        DatabaseMailItemId = @DatabaseMailItemId,
                        EmailError = @EmailError
                    FROM dbo.Monitor_Blocking mb
                    INNER JOIN @AlertLogRows r ON r.LogDateTime = mb.LogDateTime AND r.LogId = mb.LogId;
                END TRY
                BEGIN CATCH
                    -- Preserve the original error; an unupdated sending claim expires after five minutes.
                END CATCH;
            END;

            IF @ApplicationLockHeld = 1
            BEGIN
                EXEC sys.sp_releaseapplock
                    @Resource = N'dbo.Alert_Blocking.EmailThrottle',
                    @LockOwner = 'Session';
                SET @ApplicationLockHeld = 0;
            END;

            THROW;
        END CATCH;
    END;
    --In Debug Mode = 2, just return the Email HTML as a single value resultset.
    IF @Debug = 2
    BEGIN
        INSERT INTO dbo.Monitor_Blocking (AlertId, EmailStatus, LeadingBlocker, DbName, HostName, ProgramName, LoginName, LoginTime, LastRequestStart,
                        LastRequestEnd, TransactionCnt, Command, WaitTime, WaitResource, SqlText, SqlStatement, BlockedSpidCount)
        SELECT @AlertId, 'debug', LeadingBlocker, DbName, HostName, ProgramName, LoginName, LoginTime, LastRequestStart,
               LastRequestEnd, TransactionCnt, Command, WaitTime, WaitResource, SqlText, SqlStatement, BlockedSpidCount
        FROM #LeadingBlocker lb
        WHERE BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,BlockedSpidCount);

        SELECT EmailBody = @EmailBody;
    END;
END;
GO


