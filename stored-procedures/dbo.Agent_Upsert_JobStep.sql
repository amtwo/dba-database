CREATE OR ALTER PROCEDURE dbo.Agent_Upsert_JobStep
    @job_name          SYSNAME,
    @step_id           INT,
    @step_name         SYSNAME,
    @subsystem         NVARCHAR(40),
    @command           NVARCHAR(MAX),
    @database_name     SYSNAME      = NULL,
    @proxy_name        SYSNAME      = NULL,
    @on_success_action TINYINT      = 1,
    @on_fail_action    TINYINT      = 2,
    @retry_attempts    INT          = 0,
    @retry_interval    INT          = 0,
    @flags             INT          = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260614
    Idempotent wrapper around msdb.dbo.sp_add_jobstep / sp_update_jobstep.
    A step is identified within its job by @step_id. Creates the step if that
    id doesn't exist on the job, otherwise updates it in place.

    @database_name applies to TSQL steps; @proxy_name selects a run-as proxy.
    Leave either NULL to omit (runs as the Agent service account / no proxy).

    Part of SQL Agent Deploy Handler (https://github.com/amtwo/SQL-Agent-Deploy-Handler).

PARAMETERS
* These mirror the parameters of sp_add_jobstep / sp_update_jobstep, but with @job_name as the first parameter for easier use.

EXAMPLES:


**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    DECLARE @job_id UNIQUEIDENTIFIER = (
        SELECT job_id FROM msdb.dbo.sysjobs WHERE [name] = @job_name
    );
    IF @job_id IS NULL
    BEGIN
        DECLARE @msg NVARCHAR(512) =
            N'Agent_Upsert_JobStep: job ' + QUOTENAME(@job_name) + N' does not exist.';
        THROW 50000, @msg, 1;
    END

    IF NOT EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobsteps
        WHERE job_id = @job_id AND step_id = @step_id
    )
    BEGIN
        EXEC msdb.dbo.sp_add_jobstep
            @job_name          = @job_name,
            @step_id           = @step_id,
            @step_name         = @step_name,
            @subsystem         = @subsystem,
            @command           = @command,
            @database_name     = @database_name,
            @proxy_name        = @proxy_name,
            @on_success_action = @on_success_action,
            @on_fail_action    = @on_fail_action,
            @retry_attempts    = @retry_attempts,
            @retry_interval    = @retry_interval,
            @flags             = @flags;
    END
    ELSE
    BEGIN
        EXEC msdb.dbo.sp_update_jobstep
            @job_name          = @job_name,
            @step_id           = @step_id,
            @step_name         = @step_name,
            @subsystem         = @subsystem,
            @command           = @command,
            @database_name     = @database_name,
            @proxy_name        = @proxy_name,
            @on_success_action = @on_success_action,
            @on_fail_action    = @on_fail_action,
            @retry_attempts    = @retry_attempts,
            @retry_interval    = @retry_interval,
            @flags             = @flags;
    END
END
GO
