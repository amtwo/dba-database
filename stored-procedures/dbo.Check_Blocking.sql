IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Check_Blocking'))
    EXEC ('CREATE PROCEDURE dbo.Check_Blocking AS SELECT ''This is a stub''')
GO

ALTER PROCEDURE dbo.Check_Blocking
    @BlockingDurationThreshold smallint = 60,
    @BlockedSessionThreshold smallint = NULL
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20141218

PARAMETERS
* @BlockingDurationThreshold - seconds - Alters when blocked sessions have been waiting longer than this many seconds.
* @BlockedSessionThreshold - Alert if blocked session count.
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
    This code is free to download and use for personal, educational, and internal 
    corporate purposes, provided that this header is preserved. Redistribution or sale, 
    in whole or in part, is prohibited without the author's express written consent.
    ©2014-2017 ● Andy Mallon ● am2.co
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
        @Sql nvarchar(max);

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
    SessionInfo XML,
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
    SessionInfo xml,
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

    INSERT INTO #InputBuffer
    EXEC sp_executesql @sql;

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
SET SessionInfo = (SELECT LeadingBlocker,
                          LoginName, 
                          TransactionCnt, 
                          WaitResource = COALESCE(WaitDescription,WaitResource),
                          HostName,
                          DbName,
                          LastRequest = CONVERT(varchar(20),LastRequestStart,20),
                          ProgramName,
                          InputBuffer,
                          SqlStatement,
                          SqlText
                    FROM #LeadingBlocker lb2 
                    WHERE lb.id = lb2.id 
                    FOR XML PATH ('LeadBlocker'))
FROM #LeadingBlocker lb;


/*UPDATE b
SET SessionInfo = '<LoginName>' + LoginName + '</LoginName>' +
                  '<HostName>' + HostName + '</HostName>' +
                  CASE WHEN TransactionCnt <> 0 
                    THEN '<TransactionCnt>' + CAST(TransactionCnt AS nvarchar(10)) + '</TransactionCnt>' 
                    ELSE ''
                  END +
                  CASE WHEN WaitResource <> ''
                    THEN '<WaitResource>' + COALESCE(WaitDescription,WaitResource) + '</WaitResource>' 
                    ELSE ''
                  END +
                  '<DbName>' + DbName + '</DbName>' +
                  '<LastRequest>' + CONVERT(varchar(20),LastRequestStart,20) + '</LastRequest>' +
                  '<ProgramName>' + ProgramName + '</ProgramName>'
FROM #Blocked b;
*/
UPDATE b
SET SessionInfo = (SELECT WaitingSpid,
                          BlockingChain,
                          LoginName, 
                          TransactionCnt, 
                          WaitResource = COALESCE(WaitDescription,WaitResource),
                          HostName,
                          DbName,
                          LastRequest = CONVERT(varchar(20),LastRequestStart,20),
                          ProgramName,
                          InputBuffer,
                          SqlStatement,
                          SqlText
                    FROM #Blocked b2 
                    WHERE b.id = b2.id 
                    FOR XML PATH ('BlockedSession'))
FROM #Blocked b;

--output results
    IF NOT EXISTS (SELECT 1 FROM #LeadingBlocker UNION SELECT 1 FROM #Blocked)
        SELECT 'No Blocking Detected' AS Blocking;
    ELSE
    BEGIN
        SELECT * FROM #LeadingBlocker;
        SELECT * FROM #Blocked;
    END;



GO


