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

    IF @retain_step_number IS NULL OR @retain_step_number < 0
    BEGIN
        RAISERROR('@retain_step_number must be zero or greater.', 16, 1);
        RETURN;
    END;

    DECLARE @job_id uniqueidentifier = (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = @job_name),
            @step_id int,
            @return_code int;

    IF @job_id IS NULL
    BEGIN
        RAISERROR('The specified SQL Agent job does not exist or is not visible.', 16, 1);
        RETURN;
    END;

    DECLARE steps_to_prune CURSOR LOCAL STATIC READ_ONLY FOR
        SELECT step_id
        FROM msdb.dbo.sysjobsteps
        WHERE job_id = @job_id
          AND step_id > @retain_step_number
        ORDER BY step_id DESC;

    OPEN steps_to_prune;
    FETCH NEXT FROM steps_to_prune INTO @step_id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @Debug = 1
        BEGIN
            PRINT CONCAT(N'Would delete step ', @step_id, N' from job ', QUOTENAME(@job_name), N'.');
        END;
        ELSE
        BEGIN
            EXEC @return_code = msdb.dbo.sp_delete_jobstep @job_id = @job_id, @step_id = @step_id;
            IF @return_code <> 0
                THROW 50000, 'SQL Agent job-step deletion failed.', 1;
        END;

        FETCH NEXT FROM steps_to_prune INTO @step_id;
    END;

    CLOSE steps_to_prune;
    DEALLOCATE steps_to_prune;
END;
GO
