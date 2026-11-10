CREATE OR ALTER PROCEDURE dbo.Agent_Upsert_Job
    @job_name                   SYSNAME,
    @enabled                    TINYINT       = 1,
    @description                NVARCHAR(512) = N'',
    @category_name              SYSNAME       = N'[Uncategorized (Local)]',
    @owner_login_name           SYSNAME       = N'sa',
    @notify_level_email         INT           = 0,      -- 0 never, 1 success, 2 failure, 3 always
    @notify_email_operator_name SYSNAME       = NULL,
    @Debug                      bit           = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260614
    Idempotent wrapper around msdb.dbo.sp_add_job / sp_update_job.
    Creates the job if it doesn't exist, otherwise updates the mutable
    job-level properties in place. Job steps, schedules, and the job server
    are managed by their own Agent_Upsert_* procedures.

    Part of SQL Agent Deploy Handler (https://github.com/amtwo/SQL-Agent-Deploy-Handler).
       
PARAMETERS
* These mirror the parameters of sp_add_job / sp_update_job, but with @job_name as the first parameter for easier use.
* @Debug - When 1, reports the insert or update that would be made without changing the job.

EXAMPLES:
* Preview the insert or update without changing the job:
    EXEC dbo.Agent_Upsert_Job @job_name = N'Nightly Job', @Debug = 1;

MODIFICATIONS:
    20261101 - Add @Debug preview output for job inserts and updates.

**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    /*
        On RDS we need to do some special handling:
            - the owner MUST be the creating user
            - We can't use custom categories. We SKIP creating the category, so it's [Uncategorized (Local)]
    */

    IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'rdsadmin')
    BEGIN
        SET @owner_login_name = current_user;

        IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE [name] = @category_name AND category_class = 1)
        BEGIN
            SET @category_name = '[Uncategorized (Local)]';
        END;
    END;

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = @job_name)
    BEGIN
        IF @Debug = 1
        BEGIN
            PRINT N'Debug mode: would INSERT SQL Agent job ' + COALESCE(QUOTENAME(@job_name), N'<NULL>') + N'; requested values follow.';

            SELECT
                JobName                   = @job_name,
                Enabled                   = @enabled,
                Description               = @description,
                CategoryName              = @category_name,
                OwnerLoginName            = @owner_login_name,
                NotifyLevelEmail          = @notify_level_email,
                NotifyEmailOperatorName  = @notify_email_operator_name;
        END
        ELSE
        BEGIN
            EXEC msdb.dbo.sp_add_job
                @job_name                   = @job_name,
                @enabled                    = @enabled,
                @description                = @description,
                @category_name              = @category_name,
                @owner_login_name           = @owner_login_name,
                @notify_level_email         = @notify_level_email,
                @notify_email_operator_name = @notify_email_operator_name;
        END;
    END
    ELSE
    BEGIN
        IF @Debug = 1
        BEGIN
            PRINT N'Debug mode: would UPDATE SQL Agent job ' + COALESCE(QUOTENAME(@job_name), N'<NULL>') + N'; existing and requested values follow.';

            SELECT
                ExistingJobName                  = j.name,
                ExistingEnabled                  = j.enabled,
                RequestedEnabled                 = @enabled,
                ExistingDescription              = j.description,
                RequestedDescription             = @description,
                ExistingCategoryName             = c.name,
                RequestedCategoryName            = @category_name,
                ExistingOwnerLoginName           = SUSER_SNAME(j.owner_sid),
                RequestedOwnerLoginName          = CASE
                                                       WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name = N'rdsadmin')
                                                           THEN SUSER_SNAME(j.owner_sid)
                                                       ELSE @owner_login_name
                                                   END,
                ExistingNotifyLevelEmail         = j.notify_level_email,
                RequestedNotifyLevelEmail        = @notify_level_email,
                ExistingNotifyEmailOperatorName  = op.name,
                RequestedNotifyEmailOperatorName = @notify_email_operator_name
            FROM msdb.dbo.sysjobs AS j
            LEFT JOIN msdb.dbo.syscategories AS c
                ON j.category_id = c.category_id
               AND c.category_class = 1
            LEFT JOIN msdb.dbo.sysoperators AS op
                ON j.notify_email_operator_id = op.id
            WHERE j.name = @job_name;
        END
        ELSE
        BEGIN
            IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'rdsadmin')
            BEGIN
                /* You can't update the owner & passing it on an update makes it fail. So we skip it on RDS. */
                EXEC msdb.dbo.sp_update_job
                        @job_name                   = @job_name,
                        @enabled                    = @enabled,
                        @description                = @description,
                        @category_name              = @category_name,
                        @notify_level_email         = @notify_level_email,
                        @notify_email_operator_name = @notify_email_operator_name;
            END
            ELSE
            BEGIN
                EXEC msdb.dbo.sp_update_job
                        @job_name                   = @job_name,
                        @enabled                    = @enabled,
                        @description                = @description,
                        @category_name              = @category_name,
                        @owner_login_name           = @owner_login_name,
                        @notify_level_email         = @notify_level_email,
                        @notify_email_operator_name = @notify_email_operator_name;
            END
        END;
    END
END
GO
