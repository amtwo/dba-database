IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Check_OpenTransactions'))
    EXEC ('CREATE PROCEDURE dbo.Check_OpenTransactions AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Check_OpenTransactions
    @DurationThreshold smallint = 1,
    @OnlySleepingSessions bit = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20141218
    This procedure checks for locking exceeding a duration of @DurationThreshold.
    Query to identify locks is based on query from Paul Randal:
    https://www.sqlskills.com/blogs/paul/script-open-transactions-with-text-and-plans/

PARAMETERS
* @DurationThreshold - minutes - Alters when database locks have been holding log space
                       for this many minutes.
* @OnlySleepingSessions - bit - Only show sessions that are sleeping
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
    20190401 - AM2 - Add filter to only include sleeping sessions in results
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

--If we're in Debug mode, ignore @DurationThreshold parameter, Always use 1 minute.
DECLARE @Id int = 1,
        @Spid int = 0,
        @JobIdHex nvarchar(34),
        @JobName nvarchar(256),
        @Sql nvarchar(max),
        @EmailFrom varchar(max),
        @EmailBody nvarchar(max),
        @EmailSubject nvarchar(255);

CREATE TABLE #OpenTrans (
    Id int identity(1,1) PRIMARY KEY,
    Spid smallint,
    BlockingSpid smallint,
    TransactionLengthMinutes AS DATEDIFF(mi,TransactionStart,GETDATE()),
    DbName sysname,
    HostName nvarchar(128),
    ProgramName nvarchar(128),
    LoginName nvarchar(128),
    LoginTime datetime2(3),
    LastRequestStart datetime2(3),
    LastRequestEnd datetime2(3),
    TransactionCnt int,
    TransactionStart datetime2(3),
    TransactionState tinyint,
    Command nvarchar(32),
    WaitTime int,
    WaitResource nvarchar(256),
    SqlText nvarchar(max),
    SqlStatement nvarchar(max),
    InputBuffer nvarchar(4000),
    SessionInfo xml
    );

CREATE TABLE #InputBuffer (
    EventType nvarchar(30),
    Params smallint,
    EventInfo nvarchar(4000)
    );


--Grab all sessions with open transactions

INSERT INTO #OpenTrans (Spid, BlockingSpid, DbName, HostName, ProgramName, LoginName, LoginTime, LastRequestStart, 
                    LastRequestEnd, TransactionCnt, TransactionStart, TransactionState, Command, WaitTime, WaitResource, SqlText, SqlStatement)
SELECT s.session_id AS Spid, 
       r.blocking_session_id AS BlockingSpid,
       COALESCE(db_name(dt.database_id),CAST(dt.database_id as nvarchar(10))) AS DbName,
       s.host_name AS HostName,
       s.program_name AS ProgramName,
       s.login_name AS LoginName,
       s.login_time AS LoginTime,
       s.last_request_start_time AS LastRequestStart,
       s.last_request_end_time AS LastRequestEnd,
       -- Need to use sysprocesses for now until we're fully on 2012/2014
       (SELECT TOP 1 sp.open_tran FROM master.sys.sysprocesses sp WHERE sp.spid = s.session_id) AS TransactionCnt,
       --s.open_transaction_count AS TransactionCnt,
       COALESCE(dt.database_transaction_begin_time,s.last_request_start_time) AS TransactionStart,
       dt.database_transaction_state AS TransactionState,
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
JOIN sys.dm_tran_session_transactions st ON st.session_id = s.session_id
JOIN sys.dm_tran_database_transactions dt ON dt.transaction_id = st.transaction_id
LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text (r.sql_handle) t
WHERE dt.database_transaction_state NOT IN (3) -- 3 means transaction has been initialized but has not generated any log records. Ignore it
AND (@OnlySleepingSessions = 0 OR s.status = 'sleeping')
AND COALESCE(dt.database_transaction_begin_time,s.last_request_start_time) < DATEADD(mi,-1*@DurationThreshold ,GETDATE());

-- Grab the input buffer for all sessions, too.
WHILE EXISTS (SELECT 1 FROM #OpenTrans WHERE InputBuffer IS NULL)
BEGIN
    TRUNCATE TABLE #InputBuffer;
    
    SELECT TOP 1 @Spid = Spid, @Id = Id
    FROM #OpenTrans
    WHERE InputBuffer IS NULL;

    SET @Sql = 'DBCC INPUTBUFFER (' + CAST(@Spid AS varchar(10)) + ');';

    BEGIN TRY
        INSERT INTO #InputBuffer
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        PRINT 'InputBuffer Failed';
    END CATCH

    UPDATE b
    SET InputBuffer = COALESCE((SELECT TOP 1 EventInfo FROM #InputBuffer),'')
    FROM #OpenTrans b
    WHERE ID = @Id;
END;

--Convert Hex job_ids for SQL Agent jobs to names.
WHILE EXISTS(SELECT 1 FROM #OpenTrans WHERE ProgramName LIKE 'SQLAgent - TSQL JobStep (Job 0x%')
BEGIN
    SELECT @JobIdHex = '', @JobName = '';

    SELECT TOP 1 @ID = ID, 
            @JobIdHex =  SUBSTRING(ProgramName,30,34)
    FROM #OpenTrans
    WHERE ProgramName LIKE 'SQLAgent - TSQL JobStep (Job 0x%';

    SELECT @Sql = N'SELECT @JobName = name FROM msdb.dbo.sysjobs WHERE job_id = ' + @JobIdHex;
    EXEC sp_executesql @Sql, N'@JobName nvarchar(256) OUT', @JobName = @JobName OUT;

    UPDATE b
    SET ProgramName = LEFT(REPLACE(ProgramName,@JobIdHex,@JobName),128)
    FROM #OpenTrans b
    WHERE ID = @Id;
END;

-- Populate SessionInfo column with HTML details for sending email
-- Since there's a bunch of logic here, code is more readable doing this separate than mashing it in with the rest of HTML email creation
UPDATE t
SET SessionInfo = (SELECT TransactionState =
                              CASE TransactionState
                                            WHEN 1 THEN 'The transaction has not been initialized.'
                                            WHEN 3 THEN 'The transaction has been initialized but has not generated any log records.' -- We don�t alert on this status
                                            WHEN 4 THEN 'The transaction has generated log records.'
                                            WHEN 5 THEN 'The transaction has been prepared.'
                                            WHEN 10 THEN 'The transaction has been committed.'
                                            WHEN 11 THEN 'The transaction has been rolled back.'
                                            WHEN 12 THEN 'The transaction is being committed. In this state the log record is being generated, but it has not been materialized or persisted.'
                                            ELSE CAST(TransactionState as varchar)
                                      END,
                            TransactionLengthMinutes = CONVERT(varchar(20),TransactionLengthMinutes,20),
                            SessionID = Spid,
                            DbName,
                            LoginName,
                            HostName,
                            DbName,
                            WaitResource,
                            LoginTime = CONVERT(varchar(20),LoginTime,20),
                            LastRequest = CONVERT(varchar(20),LastRequestStart,20),
                            ProgramName
                    FROM #OpenTrans t2 
                    WHERE t2.id = t.id
                    FOR XML PATH ('Transaction') )
FROM #OpenTrans t;


--output results in debug mode:
    IF NOT EXISTS (SELECT 1 FROM #OpenTrans)
        SELECT 'No Open Transactions longer than ' + CAST(@DurationThreshold AS varchar(10)) + ' minutes exist' AS OpenTransactions;
    ELSE
    BEGIN
        SELECT * FROM #OpenTrans;
    END;

GO


