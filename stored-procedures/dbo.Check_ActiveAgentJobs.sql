CREATE OR ALTER PROCEDURE dbo.Check_ActiveAgentJobs
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260822
    This checks for currently-running SQL Agent jobs and returns the session_id, job name, 
    execution status, and a link to the sp_whoisactive output for that session.

    Also returns the output of sp_whoisactive for all SQL Agent sessions.

    Important Note: 
    WhoIsActive returns the program_name as "SQLAgent - TSQL JobStep (Job 0x<hex job_id>)" which is not very useful.
    The first result set replaces the hex job_id with the actual job name for easier identification.
       
PARAMETERS
NONE
EXAMPLES:

**************************************************************************************************
MODIFICATIONS:
    20150107 - 
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

BEGIN
    CREATE TABLE #Jobs (
        session_id      int,
        JobName         nvarchar(128),
        ExecutionStatus nvarchar(256),
        AdditionalDetails AS CONCAT(N'EXEC dbo.sp_whoisactive ',session_id)
    );

    INSERT INTO #Jobs (session_id, JobName, ExecutionStatus)
    SELECT s.session_id,
            jn.JobName,
            CASE
                WHEN s.program_name LIKE 'SQLAgent - TSQL JobStep (Job 0x%'
                    THEN REPLACE(s.program_name,SUBSTRING(s.program_name,30,34),jn.JobName)
                ELSE s.program_name
            END
    FROM sys.dm_exec_sessions s
    OUTER APPLY (SELECT TOP 1 JobName = j.name 
                    FROM msdb.dbo.sysjobs j 
                    WHERE j.job_id = CONVERT(varbinary(100),SUBSTRING(s.program_name,30,34),1)) jn
    WHERE s.program_name LIKE 'SQLAgent - TSQL JobStep (Job 0x%';


    SELECT * FROM #Jobs

    EXEC dbo.sp_WhoIsActive @filter_type = 'program', @filter = 'SQLAgent%'

END
