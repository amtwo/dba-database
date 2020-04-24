IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Cleanup_BackupHistory'))
    EXEC ('CREATE PROCEDURE dbo.Cleanup_BackupHistory AS SELECT ''This is a stub''')
GO

ALTER PROCEDURE dbo.Cleanup_BackupHistory
    @oldest_date datetime
AS
/*************************************************************************************************
AUTHOR: Erik Darling
CREATED: 20190329
    Originally sp_delete_backuphistory_pro
    This procedure cleans up the msdb backup history, using temp tables to manage what data needs
    to be deleted. This should improve performance compared to the standard MS-provided
    sp_delete_backuphistory.

PARAMETERS
* @oldest_date - datetime - Oldest date/time to retain backup history for
**************************************************************************************************
MODIFICATIONS:
    20190329 - AM2 - Erik hates semicolons, but I love them. 

**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
 BEGIN
   SET NOCOUNT ON;

   CREATE TABLE #backup_set_id      (backup_set_id INT PRIMARY KEY CLUSTERED);
   CREATE TABLE #media_set_id       (media_set_id INT PRIMARY KEY CLUSTERED);
   CREATE TABLE #restore_history_id (restore_history_id INT PRIMARY KEY CLUSTERED);

   INSERT INTO #backup_set_id WITH (TABLOCKX) (backup_set_id)
   SELECT DISTINCT backup_set_id
   FROM msdb.dbo.backupset
   WHERE backup_finish_date < @oldest_date;

   INSERT INTO #media_set_id WITH (TABLOCKX) (media_set_id)
   SELECT DISTINCT media_set_id
   FROM msdb.dbo.backupset
   WHERE backup_finish_date < @oldest_date;

   INSERT INTO #restore_history_id WITH (TABLOCKX) (restore_history_id)
   SELECT DISTINCT restore_history_id
   FROM msdb.dbo.restorehistory
   WHERE backup_set_id IN (SELECT backup_set_id
                           FROM   #backup_set_id);

   BEGIN TRANSACTION;

   DELETE FROM msdb.dbo.backupfile
   WHERE backup_set_id IN (SELECT backup_set_id
                           FROM   #backup_set_id);
   IF (@@error > 0)
     GOTO Quit;

   DELETE FROM msdb.dbo.backupfilegroup
   WHERE backup_set_id IN (SELECT backup_set_id
                           FROM   #backup_set_id);
   IF (@@error > 0)
     GOTO Quit;

   DELETE FROM msdb.dbo.restorefile
   WHERE restore_history_id IN (SELECT restore_history_id
                                FROM   #restore_history_id);
   IF (@@error > 0)
     GOTO Quit;

   DELETE FROM msdb.dbo.restorefilegroup
   WHERE restore_history_id IN (SELECT restore_history_id
                                FROM   #restore_history_id);
   IF (@@error > 0)
     GOTO Quit;

   DELETE FROM msdb.dbo.restorehistory
   WHERE restore_history_id IN (SELECT restore_history_id
                                FROM   #restore_history_id);
   IF (@@error > 0)
     GOTO Quit;

   DELETE FROM msdb.dbo.backupset
   WHERE backup_set_id IN (SELECT backup_set_id
                           FROM   #backup_set_id);
   IF (@@error > 0)
     GOTO Quit;

   DELETE msdb.dbo.backupmediafamily
   FROM msdb.dbo.backupmediafamily bmf
   WHERE bmf.media_set_id IN (SELECT media_set_id
                              FROM   #media_set_id)
     AND ((SELECT COUNT(*)
           FROM msdb.dbo.backupset
           WHERE media_set_id = bmf.media_set_id) = 0);
   IF (@@error > 0)
     GOTO Quit;

   DELETE msdb.dbo.backupmediaset
   FROM msdb.dbo.backupmediaset bms
   WHERE bms.media_set_id IN (SELECT media_set_id
                              FROM   #media_set_id)
     AND ((SELECT COUNT(*)
           FROM msdb.dbo.backupset
           WHERE media_set_id = bms.media_set_id) = 0);
   IF (@@error > 0)
     GOTO Quit;

   COMMIT TRANSACTION;
   RETURN;

 Quit:
   ROLLBACK TRANSACTION;

 END
 GO