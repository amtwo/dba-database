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
        EXEC msdb.dbo.sp_add_category
            @class = N'JOB',
            @type  = N'LOCAL',
            @name  = @name;
    END
END
GO
