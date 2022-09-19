IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Cleanup_Msdb'))
    EXEC ('CREATE PROCEDURE dbo.Cleanup_Msdb AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Cleanup_Msdb
    @RetainDays int = 30
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20150618
    This procedure cleans up data in msdb as part of standard retention.
    Call system stored procs when possible to do cleanup for us.
    Reorganize big tables after cleanup to get space back, or msdb will be huge.

    Cleanup based on code from MADK

PARAMETERS
* @RetainDays - number of days to retain data in msdb
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDD - 
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

DECLARE @RetainDate datetime2;

SELECT @RetainDate = DATEADD(DAY,-1*@RetainDays,SYSDATETIME());

-- Delete backup history
EXEC dbo.Cleanup_BackupHistory @oldest_date = @RetainDate;

-- Delete the SQL Server agent job history log
EXEC msdb.dbo.sp_purge_jobhistory @oldest_date = @RetainDate;

-- Delete the log of the sent items
EXEC msdb.dbo.sysmail_delete_log_sp @logged_before = @RetainDate;

-- Delete old mail items
EXEC msdb.dbo.sysmail_delete_mailitems_sp @sent_before = @RetainDate;

-- Run PBM cleanup
-- Retention based on SELECT current_value FROM msdb.dbo.syspolicy_configuration WHERE name = N'HistoryRetentionInDays'; 
-- Set retention with sp_syspolicy_set_config_history_retention [ @value = ] value
EXEC msdb.dbo.sp_syspolicy_purge_history;

--And do index maintenance
-- if you aren't doing index maintenance on msdb, we'll force it here
-- sometimes this prevents significant space bloat, esp on older versions
DECLARE @Sql nvarchar(max) = N''
SELECT @Sql = @Sql + N'ALTER INDEX ' + QUOTENAME(i.name) + N' ON [msdb].' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N' REORGANIZE;' + CHAR(10)
FROM msdb.sys.tables t
JOIN msdb.sys.indexes i ON t.object_id = i.object_id
JOIN msdb.sys.partitions p ON i.object_id = p.OBJECT_ID AND i.index_id = p.index_id
JOIN msdb.sys.schemas s ON t.schema_id = s.schema_id
WHERE p.rows > 1000;


EXEC sys.sp_executesql @Sql
GO


