IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'IF' AND object_id = object_id('dbo.AgentJob_Status'))
    EXEC ('CREATE FUNCTION dbo.AgentJob_Status() RETURNS TABLE AS RETURN SELECT Result = ''This is a stub'';' )
GO


ALTER FUNCTION dbo.AgentJob_Status (@JobName sysname)
RETURNS TABLE
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20151225
    Alternative to xp_sqlagent_enum_jobs. Use this TVF to determine a job's execution status
    
LIMITATIONS:
    This function queries the underlying msdb tables directly. If you don't have permission to the
    underlying msdb schema (ex, on AWS RDS), this will fail with permission errors. 
    Use msdb.dbo.sp_help_job______ system stored procedures instead.
    
PARAMETERS:
    @JobName - Text string of a job's name (from msdb.dbo.sysjobs.name)
EXAMPLES:
* SELECT j.name, s.* FROM msdb.dbo.sysjobs j CROSS APPLY dbo.AgentJob_Status (j.name) s
**************************************************************************************************
MODIFICATIONS:
    20160218 - More info here: https://am2.co/2016/02/xp_sqlagent_enum_jobs_alt/
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
RETURN
    SELECT
        IsRunning = running.IsRunning,
        LastRunTime = COALESCE(ja.start_execution_date, historyTime.RunStartDateTime),
        NextRunTime = ja.next_scheduled_run_date,
        LastJobStep = js.step_name,
        JobOutcome = CASE
                         WHEN running.IsRunning = 1 THEN 'Running'
                         WHEN jh.run_status = 0 THEN 'Failed'
                         WHEN jh.run_status = 1 THEN 'Succeeded'
                         WHEN jh.run_status = 2 THEN 'Retry'
                         WHEN jh.run_status = 3 THEN 'Cancelled'
                     END
    FROM msdb.dbo.sysjobs AS j
    LEFT JOIN msdb.dbo.sysjobactivity AS ja
        ON ja.job_id = j.job_id
        AND ja.session_id = (SELECT MAX(activity.session_id) FROM msdb.dbo.sysjobactivity AS activity)
    CROSS APPLY (VALUES (
        CASE WHEN ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL THEN 1 ELSE 0 END
    )) AS running(IsRunning)
    LEFT JOIN msdb.dbo.sysjobsteps AS js
        ON js.job_id = ja.job_id
        AND js.step_id = ja.last_executed_step_id
    OUTER APPLY (
        SELECT TOP (1) h.run_status, h.run_date, h.run_time, h.run_duration
        FROM msdb.dbo.sysjobhistory AS h
        WHERE h.job_id = j.job_id
          AND h.step_id = 0
          AND h.run_status IN (0, 1, 2, 3)
        ORDER BY h.instance_id DESC
    ) AS jh
    OUTER APPLY dbo.AgentJobHistory_TimeConvert(jh.run_date, jh.run_time, jh.run_duration) AS historyTime
    WHERE j.name = @JobName;
GO
