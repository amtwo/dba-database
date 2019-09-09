IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'IF' AND object_id = object_id('dbo.AgentJob_Status'))
    EXEC ('CREATE FUNCTION dbo.AgentJob_Status() RETURNS TABLE AS RETURN SELECT Result = ''This is a stub'';' )
GO


ALTER FUNCTION dbo.AgentJob_Status (@JobName sysname)
RETURNS TABLE
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20151225
    Alternative to xp_sqlagent_enum_jobs. Use this TVF to determine a job's execution status
PARAMETERS:
    @JobName - Text string of a job's name (from msdb.dbo.sysjobs.name)
EXAMPLES:
* SELECT j.name, s.* FROM msdb.dbo.sysjobs j CROSS APPLY dbo.AgentJob_Status (j.name) s
**************************************************************************************************
MODIFICATIONS:
    20160218 - More info here: https://am2.co/2016/02/xp_sqlagent_enum_jobs_alt/
**************************************************************************************************
    This code is licensed under the GNU GPL, as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2019 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
RETURN
    SELECT TOP 1
        IsRunning = CASE WHEN ja.job_id IS NOT NULL AND ja.stop_execution_date IS NULL THEN 1 ELSE 0 END,
        LastRunTime = ja.start_execution_date,
        NextRunTime = ja.next_scheduled_run_date,
        LastJobStep = js.step_name,
        JobOutcome = CASE 
                        WHEN ja.job_id IS NOT NULL AND ja.stop_execution_date IS NULL THEN 'Running'
                        WHEN run_status = 0 THEN 'Failed'
                        WHEN run_status = 1 THEN 'Succeeded'
                        WHEN run_status = 2 THEN 'Retry'
                        WHEN run_status = 3 THEN 'Cancelled'
                    END
    FROM msdb.dbo.sysjobs j
    LEFT JOIN msdb.dbo.sysjobactivity ja 
        ON ja.job_id = j.job_id
        AND ja.run_requested_date IS NOT NULL
        AND ja.start_execution_date IS NOT NULL
    LEFT JOIN msdb.dbo.sysjobsteps js
        ON js.job_id = ja.job_id
        AND js.step_id = ja.last_executed_step_id
    LEFT JOIN msdb.dbo.sysjobhistory jh
        ON jh.job_id = j.job_id
        AND jh.instance_id = ja.job_history_id
    WHERE j.name = @JobName
    ORDER BY ja.start_execution_date DESC;
GO


