﻿IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Alert_Blocking'))
    EXEC ('CREATE PROCEDURE dbo.Alert_Blocking AS SELECT ''This is a stub''')
GO

ALTER PROCEDURE dbo.Alert_Blocking
    @BlockingDurationThreshold smallint = 60,
    @BlockedSessionThreshold smallint = NULL,
    @EmailRecipients varchar(max) = 'you@yourdomain.com',
    @EmailThreshold smallint = 10,
    @Debug tinyint = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20141218
    This procedure checks for blocking exceeding a duration of @BlockingDurationThreshold.
    Log the lead blocker to a table (only when not in @Debug mode).
    @Debug parameter controls whether to email blocking to @EmailRecipients or to output resultset.
    @EmailThreshold throttles email so that the server only sends email every N minutes.

PARAMETERS
* @BlockingDurationThreshold - seconds - Alters on blocked sessions that have been waiting longer than this many seconds.
* @BlockedSessionThreshold - Alert on blocking only when the number of blocked sessions is this number of higher.
* @EmailRecipients   - delimited list of email addresses. Used for sending email alert.
* @EmailThreshold    - minutes - Only send an email every this many minutes.
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

**************************************************************************************************
    This code is licensed under the GNU GPL, as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2019 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;
--READ UNCOMMITTED, since we're dealing with blocking, we don't want to make things worse.
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

---Sure, it would work if you supplied both, but the ANDing of those gets confusing to people, so easier to just do this.
IF ((@BlockingDurationThreshold IS NOT NULL AND @BlockedSessionThreshold IS NOT NULL)
    OR COALESCE(@BlockingDurationThreshold,@BlockedSessionThreshold) IS NULL)
BEGIN
    RAISERROR('Must supply either @BlockingDurationThreshold or @BlockedSessionThreshold (but not both).',16,1)
END;


DECLARE @Id int = 1,
        @Spid int = 0,
        @JobIdHex nvarchar(34),
        @JobName nvarchar(256),
        @WaitResource nvarchar(256),
        @DbName nvarchar(256),
        @ObjectName nvarchar(256),
        @IndexName nvarchar(256),
        @Sql nvarchar(max),
        @EmailFrom varchar(max),
        @EmailBody nvarchar(max),
        @EmailSubject nvarchar(255);

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

--Convert Hex job_ids for SQL Agent jobs to names.
WHILE EXISTS(SELECT 1 FROM #Blocked WHERE ProgramName LIKE 'SQLAgent - TSQL JobStep (Job 0x%')
BEGIN
    SELECT @JobIdHex = '', @JobName = '';

    SELECT TOP 1 @ID = ID, 
            @JobIdHex =  SUBSTRING(ProgramName,30,34)
    FROM #Blocked
    WHERE ProgramName LIKE 'SQLAgent - TSQL JobStep (Job 0x%';

    SELECT @Sql = N'SELECT @JobName = name FROM msdb.dbo.sysjobs WHERE job_id = ' + @JobIdHex;
    EXEC sp_executesql @Sql, N'@JobName nvarchar(256) OUT', @JobName = @JobName OUT;

    UPDATE b
    SET ProgramName = LEFT(REPLACE(ProgramName,@JobIdHex,@JobName),128)
    FROM #Blocked b
    WHERE ID = @Id;
END;

--Decypher wait resources.
DECLARE wait_cur CURSOR FOR
    SELECT WaitingSpid, WaitResource FROM #Blocked WHERE WaitResource <> '';

OPEN wait_cur;
FETCH NEXT FROM wait_cur INTO @Spid, @WaitResource;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF @WaitResource LIKE 'KEY%'
    BEGIN
        --Decypher DB portion of wait resource
        SET @WaitResource = LTRIM(REPLACE(@WaitResource,'KEY:',''));
        SET @DbName = db_name(SUBSTRING(@WaitResource,0,CHARINDEX(':',@WaitResource)));
        --now get the object name
        SET @WaitResource = SUBSTRING(@WaitResource,CHARINDEX(':',@WaitResource)+1,256);
        SELECT @Sql = 'SELECT @ObjectName = SCHEMA_NAME(o.schema_id) + ''.'' + o.name, @IndexName = i.name ' +
            'FROM [' + @DbName + '].sys.partitions p ' +
            'JOIN [' + @DbName + '].sys.objects o ON p.OBJECT_ID = o.OBJECT_ID ' +
            'JOIN [' + @DbName + '].sys.indexes i ON p.OBJECT_ID = i.OBJECT_ID  AND p.index_id = i.index_id ' +
            'WHERE p.hobt_id = SUBSTRING(@WaitResource,0,CHARINDEX('' '',@WaitResource))'
        EXEC sp_executesql @sql,N'@WaitResource nvarchar(256),@ObjectName nvarchar(256) OUT,@IndexName nvarchar(256) OUT',
                @WaitResource = @WaitResource, @ObjectName = @ObjectName OUT, @IndexName = @IndexName OUT
        --now populate the WaitDescription column
        UPDATE b
        SET WaitDescription = 'KEY WAIT: ' + @DbName + '.' + @ObjectName + ' (' + COALESCE(@IndexName,'') + ')'
        FROM #Blocked b
        WHERE WaitingSpid = @Spid;
    END;
    ELSE IF @WaitResource LIKE 'OBJECT%'
    BEGIN
        --Decypher DB portion of wait resource
        SET @WaitResource = LTRIM(REPLACE(@WaitResource,'OBJECT:',''));
        SET @DbName = db_name(SUBSTRING(@WaitResource,0,CHARINDEX(':',@WaitResource)));
        --now get the object name
        SET @WaitResource = SUBSTRING(@WaitResource,CHARINDEX(':',@WaitResource)+1,256);
        SET @Sql = 'SELECT @ObjectName = schema_name(schema_id) + ''.'' + name FROM [' + @DbName + '].sys.objects WHERE object_id = SUBSTRING(@WaitResource,0,CHARINDEX('':'',@WaitResource))';
        EXEC sp_executesql @sql,N'@WaitResource nvarchar(256),@ObjectName nvarchar(256) OUT',@WaitResource = @WaitResource, @ObjectName = @ObjectName OUT;
        --Now populate the WaitDescription column
        UPDATE b
        SET WaitDescription = 'OBJECT WAIT: ' + @DbName + '.' + @ObjectName
        FROM #Blocked b
        WHERE WaitingSpid = @Spid;
    END;
    ELSE IF (@WaitResource LIKE 'PAGE%' OR @WaitResource LIKE 'RID%')
    BEGIN
        --Decypher DB portion of wait resource
        SELECT @WaitResource = LTRIM(REPLACE(@WaitResource,'PAGE:',''));
        SELECT @WaitResource = LTRIM(REPLACE(@WaitResource,'RID:',''));
        SET @DbName = db_name(SUBSTRING(@WaitResource,0,CHARINDEX(':',@WaitResource)));
        --now get the file name
        SET @WaitResource = SUBSTRING(@WaitResource,CHARINDEX(':',@WaitResource)+1,256)
        SELECT @ObjectName = name 
        FROM sys.master_files
        WHERE database_id = db_id(@DbName)
        AND file_id = SUBSTRING(@WaitResource,0,CHARINDEX(':',@WaitResource));
        --Now populate the WaitDescription column
        SET @WaitResource = SUBSTRING(@WaitResource,CHARINDEX(':',@WaitResource)+1,256)
        IF @WaitResource LIKE '%:%'
        BEGIN
            UPDATE b
            SET WaitDescription = 'ROW WAIT: ' + @DbName + ' File: ' + @ObjectName + ' Page_id/Slot: ' + @WaitResource
            FROM #Blocked b
            WHERE WaitingSpid = @Spid;
        END;
        ELSE
        BEGIN
            UPDATE b
            SET WaitDescription = 'PAGE WAIT: ' + @DbName + ' File: ' + @ObjectName + ' Page_id: ' + @WaitResource
            FROM #Blocked b
            WHERE WaitingSpid = @Spid;
        END;
    END;
    FETCH NEXT FROM wait_cur INTO @Spid, @WaitResource;
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
JOIN BlockingChain bc ON b.WaitingSpid = bc.Spid;

-- Populate BlockedSpidCount for #LeadingBlocker
UPDATE lb
SET BlockedSpidCount = cnt.BlockedSpidCount
FROM #LeadingBlocker lb
JOIN (SELECT LeadingBlocker, COUNT(*) BlockedSpidCount FROM #Blocked GROUP BY LeadingBlocker) cnt 
        ON cnt.LeadingBlocker = lb.LeadingBlocker;


-- Populate SessionInfo column with HTML details for sending email
-- Since there's a bunch of logic here, code is more readable doing this separate than mashing it in with the rest of HTML email creation
UPDATE lb
SET SessionInfo = '<span style="font-weight:bold">Login = </span>' + LoginName + '<br>' +
                  CASE WHEN TransactionCnt <> 0 
                    THEN '<span style="font-weight:bold">Transaction Count = </span>' + CAST(TransactionCnt AS nvarchar(10)) + '<br>' 
                    ELSE ''
                  END +
                  CASE WHEN WaitResource <> ''
                    THEN '<span style="font-weight:bold">Wait Resource = </span>' + COALESCE(WaitDescription,WaitResource) + '<br>' 
                    ELSE ''
                  END +
                  '<span style="font-weight:bold">Host Name = </span>' + HostName + '<br>' +
                  CASE WHEN DbName <> ''
                    THEN '<span style="font-weight:bold">DbName = </span>' + DbName + '<br>' 
                    ELSE ''
                  END +
                  '<span style="font-weight:bold">Last Request = </span>' + CONVERT(varchar(20),LastRequestStart,20) + '<br>' +
                  '<span style="font-weight:bold">Program Name = </span>' + ProgramName + '<br>' 
FROM #LeadingBlocker lb;

UPDATE b
SET SessionInfo = '<span style="font-weight:bold">Login = </span>' + LoginName + '<br>' +
                  '<span style="font-weight:bold">Host Name = </span>' + HostName + '<br>' +
                  CASE WHEN TransactionCnt <> 0 
                    THEN '<span style="font-weight:bold">Transaction Count = </span>' + CAST(TransactionCnt AS nvarchar(10)) + '<br>' 
                    ELSE ''
                  END +
                  CASE WHEN WaitResource <> ''
                    THEN '<span style="font-weight:bold">Wait Resource = </span>' + COALESCE(WaitDescription,WaitResource) + '<br>' 
                    ELSE ''
                  END +
                  '<span style="font-weight:bold">DbName = </span>' + DbName + '<br>' +
                  '<span style="font-weight:bold">Last Request = </span>' + CONVERT(varchar(20),LastRequestStart,20) + '<br>' +
                  '<span style="font-weight:bold">Program Name = </span>' + ProgramName + '<br>'
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

--Check EmailThreshold before continuing. RETURN within @EmailThreshold
-- should this check be at the top of the alert?
IF EXISTS (SELECT 1 FROM dbo.Monitor_Blocking WHERE LogDateTime >= DATEADD(mi,-1*@EmailThreshold,GETDATE()))
BEGIN
    RETURN(0);
END;

-- Logging & Email Only happens when @Debug = 0
IF @Debug IN (0,2) 
BEGIN
    --Log leading blockers to a real table, too.
    INSERT INTO dbo.Monitor_Blocking (LeadingBlocker, DbName, HostName, ProgramName, LoginName, LoginTime, LastRequestStart, 
                        LastRequestEnd, TransactionCnt, Command, WaitTime, WaitResource, SqlText, SqlStatement, BlockedSpidCount)
    SELECT LeadingBlocker, DbName, HostName, ProgramName, LoginName, LoginTime, LastRequestStart, 
                        LastRequestEnd, TransactionCnt, Command, WaitTime, WaitResource, SqlText, SqlStatement, BlockedSpidCount
    FROM #LeadingBlocker lb
    WHERE BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,BlockedSpidCount);

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
            CAST(( SELECT
                    td = CAST(LeadingBlocker AS nvarchar(10)), '',
                    td = CAST(BlockedSpidCount AS nvarchar(10)), '',
                    td = SessionInfo ,'',
                    td = LEFT(SqlStatement,300), '',    --Truncate string, too long for email alert
                    td = LEFT(InputBuffer,300), ''      --Truncate string, too long for email alert
                    FROM #LeadingBlocker
                    WHERE BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,BlockedSpidCount)
                    ORDER BY LoginTime
                    FOR XML PATH ('tr'), ELEMENTS
                    ) AS nvarchar(max)) +
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
            CAST(( SELECT
                    td = CAST(WaitingSpid AS nvarchar(10)), '',
                    td = RIGHT(BlockingChain,18), '',   -- We just want the leading blocker & a few spids leading up to that
                    td = CAST(WaitTime/1000 AS nvarchar(10)), '',
                    td = SessionInfo ,'',
                    td = LEFT(SqlStatement,300), '',    --Truncate string, too long for email alert
                    td = LEFT(InputBuffer,300), ''      --Truncate string, too long for email alert
                    FROM #Blocked b
                    WHERE EXISTS (SELECT 1 FROM #LeadingBlocker lb 
                                WHERE lb.LeadingBlocker = b.LeadingBlocker
                                AND lb.BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,lb.BlockedSpidCount))
                    ORDER BY WaitTime desc
                    FOR XML PATH ('tr'), ELEMENTS
                    ) AS nvarchar(max)) +
            N'</table>';
    
    SELECT @EmailBody = @EmailBody + '<hr>' + dbo.EmailServerInfo_Get();

    SELECT @EmailBody = REPLACE(@EmailBody,'&lt;','<');
    SELECT @EmailBody = REPLACE(@EmailBody,'&gt;','>');

    --In Debug Mode = 0, send the email
    IF (@Debug = 0)
    BEGIN
        SET @EmailSubject = 'ALERT: Blocking Detected';
        SET @EmailFrom = @@SERVERNAME + ' <' + REPLACE(@@SERVERNAME,'\','_') + '@yourdomain.com>';

        EXEC msdb.dbo.sp_send_dbmail
            @recipients = @EmailRecipients,
            @from_address = @EmailFrom,
            @subject = @EmailSubject,
            @body = @EmailBody,
            @body_format = 'HTML',
            @importance = 'High';
    END;
    --In Debug Mode = 2, just return the Email HTML as a single value resultset.
    IF @Debug = 2
    BEGIN
        SELECT EmailBody = @EmailBody;
    END;
END;
GO


