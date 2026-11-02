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
* @BlockingDurationThreshold - seconds - Shows blocked sessions that have been waiting longer than this many seconds.
* @BlockedSessionThreshold - Shows blocking only when the number of blocked sessions is this number or higher.
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
    20261101 - Cody - Decode TAB wait resources to object and index names.
    20261101 - Cody - Use shared wait-resource and SQL Agent job ID functions.

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
    OR COALESCE(@BlockingDurationThreshold, @BlockedSessionThreshold) IS NULL)
BEGIN
    RAISERROR('Must supply either @BlockingDurationThreshold or @BlockedSessionThreshold (but not both).',16,1);
    RETURN;
END;


DECLARE @Id int = 1,
        @Spid int = 0,
        @WaitResource nvarchar(256),
        @ResourceType varchar(8),
        @DbName nvarchar(256),
        @ObjectId int,
        @SchemaName sysname,
        @ObjectName nvarchar(256),
        @IndexName nvarchar(256),
        @IndexId int,
        @HobtId bigint,
        @FileId int,
        @FileName sysname,
        @PageId bigint,
        @SlotId int,
        @BlockedRowId int,
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
                          LoginName = dbo.XmlSafeText_Get(LoginName),
                          TransactionCnt, 
                          WaitResource = dbo.XmlSafeText_Get(COALESCE(WaitDescription,WaitResource)),
                          HostName = dbo.XmlSafeText_Get(HostName),
                          DbName = dbo.XmlSafeText_Get(DbName),
                          LastRequest = CONVERT(varchar(20),LastRequestStart,20),
                          ProgramName = dbo.XmlSafeText_Get(ProgramName),
                          InputBuffer = dbo.XmlSafeText_Get(InputBuffer),
                          SqlStatement = dbo.XmlSafeText_Get(SqlStatement),
                          SqlText = dbo.XmlSafeText_Get(SqlText)
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
                          BlockingChain = dbo.XmlSafeText_Get(BlockingChain),
                          LoginName = dbo.XmlSafeText_Get(LoginName),
                          TransactionCnt, 
                          WaitResource = dbo.XmlSafeText_Get(COALESCE(WaitDescription,WaitResource)),
                          HostName = dbo.XmlSafeText_Get(HostName),
                          DbName = dbo.XmlSafeText_Get(DbName),
                          LastRequest = CONVERT(varchar(20),LastRequestStart,20),
                          ProgramName = dbo.XmlSafeText_Get(ProgramName),
                          InputBuffer = dbo.XmlSafeText_Get(InputBuffer),
                          SqlStatement = dbo.XmlSafeText_Get(SqlStatement),
                          SqlText = dbo.XmlSafeText_Get(SqlText)
                    FROM #Blocked b2 
                    WHERE b.id = b2.id 
                    FOR XML PATH ('BlockedSession'))
FROM #Blocked b;

--output results
    IF NOT EXISTS (SELECT 1 FROM #LeadingBlocker WHERE BlockedSpidCount >= COALESCE(@BlockedSessionThreshold,BlockedSpidCount))
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



GO


