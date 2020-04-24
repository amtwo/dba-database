IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Cleanup_CommandLog'))
    EXEC ('CREATE PROCEDURE dbo.Cleanup_CommandLog AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Cleanup_CommandLog
    @RetainDays_Backup  int = 30,
    @RetainDays_DBCC    int = 180,
    @RetainDays_Index   int = 180,
    @RetainDays_Stats   int = 180,
    @RetainDays_Other   int = 20
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20150128
    This procedure cleans up data in the CommandLog table in the DBA database.
    The CommandLog table is part of Ola Hallengren's maintenance code, but we don't
    need those logs forever.

    We should delete in batches to minimize blocking.
    But maybe I'll do that in v 2.0


PARAMETERS
* @RetainDays - number of days to retain data on Monitor_xxx tables.
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDD - 
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

DECLARE @CleanupDateTime datetime2(0);

--CommandLog Cleanup (for Ola Hallengren's logging table)
--One ugly statement so just scan the table once.
-- 
DELETE c
FROM dbo.CommandLog c
WHERE 1=1
AND (
    --Backups
    (StartTime <= DATEADD(dd,-1*@RetainDays_Backup,GETDATE())
        AND CommandType IN ('BACKUP_DATABASE','BACKUP_LOG','RESTORE_VERIFYONLY'))
    OR 
    --DBCC
    (StartTime <= DATEADD(dd,-1*@RetainDays_DBCC,GETDATE())
        AND CommandType IN ('DBCC_CHECKDB'))
    OR 
    --Index
    (StartTime <= DATEADD(dd,-1*@RetainDays_Index,GETDATE())
        AND CommandType IN ('ALTER_INDEX'))
    OR 
    --Stats
    (StartTime <= DATEADD(dd,-1*@RetainDays_Stats,GETDATE())
        AND CommandType IN ('UPDATE_STATISTICS'))
    OR 
    --Other
    (StartTime <= DATEADD(dd,-1*@RetainDays_Other,GETDATE())
        AND CommandType IN ('xp_create_subdir','xp_delete_file'))
    )
GO


