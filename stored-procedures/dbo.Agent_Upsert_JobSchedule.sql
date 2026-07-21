CREATE OR ALTER PROCEDURE dbo.Agent_Upsert_JobSchedule
    @job_name               SYSNAME,
    @name                   SYSNAME,
    @enabled                TINYINT = 1,
    @freq_type              INT,
    @freq_interval          INT,
    @freq_recurrence_factor INT,
    @active_start_time      INT
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260614
    Idempotent wrapper around msdb.dbo.sp_add_jobschedule / sp_update_jobschedule.
    A schedule is identified by its @name within @job_name. Creates the schedule
    if absent, otherwise updates the existing one in place.

    Note: sp_update_jobschedule takes @new_name for renames; this wrapper keeps the
    name stable (it matches and updates by @name), so renames are treated as a new
    schedule rather than an in-place rename.

    Part of SQL Agent Deploy Handler (https://github.com/amtwo/SQL-Agent-Deploy-Handler).

PARAMETERS
* These mirror the parameters of sp_add_jobschedule / sp_update_jobschedule, but with @job_name as the first parameter for easier use.

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
            N'Agent_Upsert_JobSchedule: job ' + QUOTENAME(@job_name) + N' does not exist.';
        THROW 50000, @msg, 1;
    END

    CREATE TABLE #sysjobschedules
    (
        schedule_id            INT,
        schedule_name          SYSNAME,
        enabled                INT,
        freq_type              INT,
        freq_interval          INT,
        freq_subday_type       INT,
        freq_subday_interval   INT,
        freq_relative_interval INT,
        freq_recurrence_factor INT,
        active_start_date      INT,
        active_end_date        INT,
        active_start_time      INT,
        active_end_time        INT,
        date_created           DATETIME,
        schedule_description   NVARCHAR(4000),
        next_run_date          INT,
        next_run_time          INT,
        schedule_uid           UNIQUEIDENTIFIER,
        job_count              INT
    );

    INSERT INTO #sysjobschedules
    EXEC msdb.dbo.sp_help_jobschedule @job_id = @job_id;

    IF NOT EXISTS (
        SELECT 1
        FROM #sysjobschedules js
        WHERE js.schedule_name = @name
    )
    BEGIN
        EXEC msdb.dbo.sp_add_jobschedule
            @job_name               = @job_name,
            @name                   = @name,
            @enabled                = @enabled,
            @freq_type              = @freq_type,
            @freq_interval          = @freq_interval,
            @freq_recurrence_factor = @freq_recurrence_factor,
            @active_start_time      = @active_start_time;
    END
    ELSE
    BEGIN
        EXEC msdb.dbo.sp_update_jobschedule
            @job_name               = @job_name,
            @name                   = @name,
            @enabled                = @enabled,
            @freq_type              = @freq_type,
            @freq_interval          = @freq_interval,
            @freq_recurrence_factor = @freq_recurrence_factor,
            @active_start_time      = @active_start_time;
    END
END
GO
