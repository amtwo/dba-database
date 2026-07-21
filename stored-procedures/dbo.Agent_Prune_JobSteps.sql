CREATE OR ALTER PROCEDURE dbo.Agent_Prune_JobSteps
    @job_name                   SYSNAME,
    @retain_step_number         int,
    @Debug                      bit = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260614
    Idempotent wrapper to make sure that if a job step is REMOVED, we don't leave an extra
    jobstep dangling around. This is a "prune" operation: it deletes any job steps with step_id > @retain_step_number.

    Part of SQL Agent Deploy Handler (https://github.com/amtwo/SQL-Agent-Deploy-Handler).
       
PARAMETERS
* 

EXAMPLES:


**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    DECLARE @job_id UNIQUEIDENTIFIER = (SELECT job_id FROM msdb.dbo.sysjobs WHERE [name] = @job_name);

    CREATE TABLE #sysjobsteps
    (
        step_id              INT,
        step_name            SYSNAME,
        subsystem            NVARCHAR(40),
        command              NVARCHAR(MAX),
        flags                INT,
        cmdexec_success_code INT,
        on_success_action    TINYINT,
        on_success_step_id   INT,
        on_fail_action       TINYINT,
        on_fail_step_id      INT,
        server               NVARCHAR(128),
        database_name        NVARCHAR(128),
        database_user_name   NVARCHAR(128),
        retry_attempts       INT,
        retry_interval       INT,
        os_run_priority      INT,
        output_file_name     NVARCHAR(200),
        last_run_outcome     INT,
        last_run_duration    INT,
        last_run_retries     INT,
        last_run_date        INT,
        last_run_time        INT,
        proxy_id             INT
    );

    INSERT INTO #sysjobsteps
    EXEC msdb.dbo.sp_help_jobstep @job_id = @job_id;


    DECLARE @pruneSql NVARCHAR(MAX) = N'';
    SELECT @pruneSql = @pruneSql
            + N'EXEC msdb.dbo.sp_delete_jobstep @job_id = @jid, @step_id = ' + CONVERT(nvarchar(max),js.step_id) + N';'
            + NCHAR(13) + NCHAR(10)
    FROM #sysjobsteps AS js
    WHERE js.step_id > 1;

    IF (@pruneSql <> N'')
    BEGIN
        IF @Debug = 1
        BEGIN
            EXEC dbo.Debug_Print @DebugMessage = @pruneSql;
        END
        ELSE
            EXEC sys.sp_executesql @pruneSql, N'@jn SYSNAME', @jid = @job_id;
        END


END
GO
