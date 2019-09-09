IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Check_LogVLF'))
    EXEC ('CREATE PROCEDURE dbo.Check_LogVLF AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Check_LogVLF
    @Threshold tinyint = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20141001
    This checks all tran logs for the number of VLFs. When transaction logs contains
    "too many" VLFs, it can impact database recovery & failover.
    The @Threshold controls what DBs should be included in the result set
       
PARAMETERS
* @Threshold - Default 0 - Number of VLFs. Can be used to filter out databases with a small 
                number of VLFs, in case you don't care about those.
EXAMPLES:

**************************************************************************************************
MODIFICATIONS:
    20150107 - 
**************************************************************************************************
    This code is licensed under the GNU GPL, as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2019 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

DECLARE @DbName sysname,
        @SQL nvarchar(max)

CREATE TABLE #Results (
    DbName sysname, 
    LogFileName sysname, 
    PhysicalName sysname, 
    Growth sysname, 
    VLF int);

CREATE TABLE #LogInfo
  (RecoveryUnitID tinyint,
   fileid tinyint,
   file_size bigint,
   start_offset bigint,
   FSeqNo int,
   [status] tinyint,
   parity tinyint,
   create_lsn numeric(25,0) );


--INSERT INTO #Results (DbName, LogFileName, PhysicalName, Growth)
EXEC sp_foreachdb @suppress_quotename = 1, @command = 'INSERT INTO #Results (DbName, LogFileName, PhysicalName, Growth)
      SELECT ''?'' , name, physical_name,
            CASE WHEN growth  = 0 THEN ''fixed'' ELSE
              CASE WHEN is_percent_growth = 0 THEN CONVERT(varchar(10), (growth/128)) + '' MB''
              WHEN  is_percent_growth = 1 THEN CONVERT(varchar(10), growth) +'' PERCENT''  END
              END AS [growth]
       FROM [?].sys.database_files 
       WHERE type_desc = ''LOG'';  ';


DECLARE db_cur CURSOR FOR
  SELECT dbname FROM #Results ORDER BY dbname;
  
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;
WHILE @@FETCH_STATUS=0
  BEGIN
    DELETE FROM #LogInfo;
    --RecoveryUnitID column is only used in 2012 and up.
    IF CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') as varchar(12)),2) as tinyint) <= 10
        SET @sql='Insert #LogInfo(fileid, file_size, start_offset, FSeqNo, [status], parity, create_lsn) Exec(''DBCC loginfo ('+QUOTENAME(@dbname)+')'')';
    ELSE 
        SET @sql='Insert #LogInfo(RecoveryUnitID, fileid, file_size, start_offset, FSeqNo, [status], parity, create_lsn) Exec(''DBCC loginfo ('+QUOTENAME(@dbname)+')'')';
    PRINT @sql;
    EXEC (@sql);
    UPDATE #Results SET vlf=(SELECT COUNT(*) FROM #LogInfo) WHERE dbname=@DbName;
    FETCH Next FROM db_cur INTO @DbName;
  END;
CLOSE db_cur;
DEALLOCATE db_cur;


SELECT * 
FROM #Results 
WHERE vlf >= @Threshold
ORDER BY VLF DESC;





GO


