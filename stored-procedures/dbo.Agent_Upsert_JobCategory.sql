CREATE OR ALTER PROCEDURE dbo.Agent_Upsert_JobCategory
    @name SYSNAME
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260614
    Idempotent wrapper around msdb.dbo.sp_add_category for JOB categories.
    A category has no meaningful "update" (only its name identifies it), so this
    is a create-if-missing: it adds the category when absent and is a no-op when
    it already exists.

    On Amazon RDS the master user is not granted EXECUTE on msdb.dbo.sp_add_category,
    so custom job categories cannot be created there. The built-in
    [Uncategorized (Local)] category always exists on every instance (including RDS),
    which covers the default case. When a non-existent category is requested on RDS,
    this proc raises an informational message and skips rather than failing, so the
    surrounding job deploy can continue.

    Part of SQL Agent Deploy Handler (https://github.com/amtwo/SQL-Agent-Deploy-Handler).

PARAMETERS
* These mirror the parameters of sp_add_category, scoped to JOB categories.

EXAMPLES:


**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM msdb.dbo.syscategories
        WHERE [name] = @name
          AND category_class = 1   -- 1 = JOB
    )
    BEGIN
        -- RDS does not grant EXECUTE on msdb.dbo.sp_add_category to the master user,
        -- so we can't create categories there. Skip with an informational message
        -- rather than failing the deploy; jobs fall back to [Uncategorized (Local)].
        IF EXISTS (SELECT 1 FROM sys.databases WHERE [name] = N'rdsadmin')
        BEGIN
            DECLARE @rdsMsg NVARCHAR(512) =
                N'Agent_Upsert_JobCategory: category ' + QUOTENAME(@name)
                + N' does not exist and cannot be created on Amazon RDS (no EXECUTE on sp_add_category). Skipping.';
            RAISERROR(@rdsMsg, 10, 1) WITH NOWAIT;
        END
        ELSE
        BEGIN
            EXEC msdb.dbo.sp_add_category
                @class = N'JOB',
                @type  = N'LOCAL',
                @name  = @name;
        END
    END
END
GO
