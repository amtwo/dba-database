IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Check_LogVLF'))
    EXEC ('CREATE PROCEDURE dbo.Check_LogVLF AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Check_LogVLF
    @Threshold tinyint = 0,
    @Debug bit = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20141001
    This checks all tran logs for the number of VLFs. When transaction logs contains
    "too many" VLFs, it can impact database recovery & failover.
    The @Threshold controls which log files are included in the result set.
       
PARAMETERS
* @Threshold - Default 0 - Number of VLFs. Can be used to filter out files with a small
                number of VLFs, in case you don't care about those.
* @Debug     - Default 0 (False) - When 1, PRINT the per-database dynamic SQL.
EXAMPLES:


**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

DECLARE @DbName sysname,
        @DbId int,
        @Sql nvarchar(max)

CREATE TABLE #Results (
    DbName sysname, 
    LogFileName sysname, 
    PhysicalName sysname, 
    Growth sysname, 
    VLF int,
    FileId int);

CREATE TABLE #LogInfo
  (RecoveryUnitID int,
   fileid int,
   file_size bigint,
   start_offset bigint,
   FSeqNo bigint,
   [status] tinyint,
   parity tinyint,
   create_lsn numeric(25,0) );


INSERT INTO #Results (DbName, LogFileName, PhysicalName, Growth, FileId)
EXEC dbo.sp_ineachdb @suppress_quotename = 1, @command = '
      SELECT db_name() , name, physical_name,
            CASE WHEN growth  = 0 THEN ''fixed'' ELSE
              CASE WHEN is_percent_growth = 0 THEN CONVERT(varchar(10), (growth/128)) + '' MB''
              WHEN  is_percent_growth = 1 THEN CONVERT(varchar(10), growth) +'' PERCENT''  END
              END AS [growth], file_id
       FROM sys.database_files 
       WHERE type_desc = ''LOG'';  ';


DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
  SELECT DISTINCT r.DbName FROM #Results AS r ORDER BY r.DbName;
  
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;
WHILE @@FETCH_STATUS=0
  BEGIN
    SET @DbId = DB_ID(@DbName);

    -- dm_db_log_info was added in SQL Server 2016 SP2; keep the DBCC path for SP1.
    IF OBJECT_ID(N'sys.dm_db_log_info') IS NOT NULL
        SET @Sql = N'UPDATE r
SET VLF = (SELECT COUNT(*) FROM sys.dm_db_log_info(@DbId) AS li WHERE li.file_id = r.FileId)
FROM #Results AS r
WHERE r.DbName = @DbName;';
    ELSE
        SET @Sql = N'DELETE FROM #LogInfo;
INSERT INTO #LogInfo (RecoveryUnitID, fileid, file_size, start_offset, FSeqNo, [status], parity, create_lsn)
EXEC sys.sp_executesql N''DBCC LOGINFO (@DbId) WITH NO_INFOMSGS;'', N''@DbId int'', @DbId = @DbId;
UPDATE r
SET VLF = (SELECT COUNT(*) FROM #LogInfo AS li WHERE li.fileid = r.FileId)
FROM #Results AS r
WHERE r.DbName = @DbName;';

    IF @Debug = 1
        EXEC dbo.Debug_Print @DebugMessage = @Sql;
    EXEC sys.sp_executesql @Sql, N'@DbId int, @DbName sysname', @DbId = @DbId, @DbName = @DbName;
    FETCH Next FROM db_cur INTO @DbName;
  END;
CLOSE db_cur;
DEALLOCATE db_cur;


SELECT r.DbName, r.LogFileName, r.PhysicalName, r.Growth, r.VLF
FROM #Results AS r
WHERE r.VLF >= @Threshold
ORDER BY r.VLF DESC;
GO
