CREATE OR ALTER PROCEDURE dbo.Agent_Upsert_Job
    @job_name                   SYSNAME,
    @enabled                    TINYINT       = 1,
    @description                NVARCHAR(512) = N'',
    @category_name              SYSNAME       = N'[Uncategorized (Local)]',
    @owner_login_name           SYSNAME       = N'sa',
    @notify_level_email         INT           = 0,      -- 0 never, 1 success, 2 failure, 3 always
    @notify_email_operator_name SYSNAME       = NULL
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

EXAMPLES:


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
        EXEC msdb.dbo.sp_add_job
            @job_name                   = @job_name,
            @enabled                    = @enabled,
            @description                = @description,
            @category_name              = @category_name,
            @owner_login_name           = @owner_login_name,
            @notify_level_email         = @notify_level_email,
            @notify_email_operator_name = @notify_email_operator_name;
    END
    ELSE
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'rdsadmin')
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
    END
END
GO
