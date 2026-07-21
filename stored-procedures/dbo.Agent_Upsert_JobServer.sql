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

    CREATE TABLE #sysjobservers
    (
        server_id      INT,
        server_name    NVARCHAR(30),
        enlist_date    DATETIME,
        last_poll_date DATETIME
    );
    
    INSERT INTO #sysjobservers
    EXEC msdb.dbo.sp_help_jobserver @job_id = @job_id;

    CREATE TABLE #systargetservers
    (
          server_id            INT,
          server_name          NVARCHAR(30),
          location             NVARCHAR(200),
          time_zone_adjustment INT,
          enlist_date          DATETIME,
          last_poll_date       DATETIME,
          status               INT,
          unread_instructions  INT,
          local_time           DATETIME,
          enlisted_by_nt_user  NVARCHAR(100),
          poll_interval        INT
    );
    
    -- sp_add_jobserver records the original server name; (LOCAL) is stored as the
    -- actual server name, so match on either form to stay idempotent.
    
    IF NOT EXISTS (SELECT 1 FROM #sysjobservers WHERE server_name = @server_name OR (server_name = @@SERVERNAME AND @server_name = N'(LOCAL)'))
    BEGIN
        IF (@server_name = N'(LOCAL)' OR @server_name = @@SERVERNAME)
        BEGIN
            EXEC msdb.dbo.sp_add_jobserver @job_id = @job_id;
            PRINT 'A'
        END;
        ELSE
        BEGIN
            EXEC msdb.dbo.sp_add_jobserver
                @job_id    = @job_id,
                @server_name = @server_name;
            PRINT 'B'
        END;
    END
    
END
GO
