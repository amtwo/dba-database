CREATE OR ALTER PROCEDURE dbo.Agent_Upsert_JobServer
    @job_name    SYSNAME,
    @server_name SYSNAME = N'(LOCAL)'
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260614
    Idempotent wrapper around msdb.dbo.sp_add_jobserver. There is no native
    "update" for a job-server target -- a job is either associated with a server
    or it isn't -- so this is a create-if-missing: it associates the job with
    @server_name when that association is absent, and is a no-op otherwise.

    Part of SQL Agent Deploy Handler (https://github.com/amtwo/SQL-Agent-Deploy-Handler).

PARAMETERS
* These mirror the parameters of sp_add_jobserver, but with @job_name as the first parameter for easier use.

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
            N'Agent_Upsert_JobServer: job ' + QUOTENAME(@job_name) + N' does not exist.';
        THROW 50000, @msg, 1;
    END

    -- sp_add_jobserver records the original server name; (LOCAL) is stored as the
    -- actual server name, so match on either form to stay idempotent.
    IF NOT EXISTS (
        SELECT 1
        FROM msdb.dbo.sysjobservers js
        WHERE js.job_id = @job_id
          AND (
                @server_name = N'(LOCAL)'
             OR js.server_id = (SELECT server_id FROM msdb.dbo.sysservers WHERE [name] = @server_name)
          )
    )
    BEGIN
        EXEC msdb.dbo.sp_add_jobserver
            @job_name    = @job_name,
            @server_name = @server_name;
    END
END
GO
