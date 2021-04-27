IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Check_FileSize'))
    EXEC ('CREATE PROCEDURE dbo.Check_FileSize AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Check_FileSize
    @DbName sysname = NULL,
    @Drive char(1) = NULL,
    @IncludeDataFiles bit = 1,
    @IncludeLogFiles bit = 1,
    @OrderBy nvarchar(100) = NULL
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20140917
       This returns data related to file size & and usage. 
PARAMETERS
* @DbName - Default NULL - Specific database to check for file size/usage. Can be wildcarded
                           When NULL, check all databases
* @Drive  - Default NULL - Specific drive letter to check for file size/usage.
                           When NULL, check all drives
* @IncludeDataFiles - Default 1 (True) - Flag to enable checking of data file sizes. Defaults to true.
* @IncludeLogFiles  - Default 1 (True) - Flag to enable checking of log file sizes. Defaults to true.
* @OrderBy - Default NULL - The value used in the order by clause of the result set.
                            When NULL or an invalid value passed, ordered by ServerName, DbName, LogicalFileName

EXAMPLES:
* Check File size/usage for internal_tracking database
    EXEC Check_FileSize @DbName = 'internal_tracking'
* Check File size/usage for all data & log files for all databases on the D drive
    EXEC Check_FileSize @Drive = 'D'
* Check File size/usage for all data files (but not logs) for the internal_tracking database on the D drive
    EXEC Check_FileSize @DbName = 'internal_tracking', @Drive = 'D', @IncludeLogFiles = 0
**************************************************************************************************
MODIFICATIONS:
       20140101 - Initials - Modification description
       20200424 - AM2 - Update to pass @DbName to sp_foreachdb like a big boy, instead of
                    just querying on the output table. This is a big difference on servers with
                    many databases
       
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

CREATE TABLE #FileSizeInfo 
  ( 
     ServerName       NVARCHAR(128), 
     DbName           NVARCHAR(128), 
     LogicalFileName  NVARCHAR(128), 
     FileType         NVARCHAR(10),
     FileSizeMB       INT, 
     SpaceUsedMB      INT, 
     FreeSpaceMB      INT, 
     FreeSpacePct     VARCHAR(7),
     GrowthAmount     VARCHAR(20), 
     PhysicalFileName NVARCHAR(520)
  );


--if no @OrderBy supplied or an invalid option, use DBName, LogicalFileName
IF (@OrderBy IS NULL 
    OR EXISTS (SELECT * FROM dbo.fn_split(REPLACE(REPLACE(@OrderBy,'ASC',''),'DESC',''),',')
            WHERE value NOT IN (SELECT name FROM tempdb.sys.columns WHERE object_id = object_id('tempdb..#FileSizeInfo') )
        ))
    SET @OrderBy = 'ServerName, DbName, LogicalFileName';

IF @DbName IS NULL
BEGIN
    SET @DbName = N'%';
END

-- Because of log-shipped databases, we want to use sys.master_files for the file location NOT sys.sysfiles
    -- sys.master_files will show the location on *this* server. 
    -- sys.sysfiles in the DB will show the location of the files on the *primary* server.
    -- Using sys.master_files has the right location in all cases.
-- Because of TempDB, we want to use sys.sysfiles for the file size, not sys.master_files
    -- sys.master_files will show the *starting* file size, not the actual file size.
    -- sys.sysfiles will show the *current* file size
    -- Using sys.sysfiles has the right current file size in all cases.

INSERT #FileSizeInfo (ServerName, DbName, FileSizeMB, SpaceUsedMB, GrowthAmount, LogicalFileName, PhysicalFileName, FileType, FreeSpaceMB, FreeSpacePct) 
EXEC dbo.sp_ineachdb 
        @suppress_quotename = 1, 
        @state_desc = 'ONLINE', 
        @name_pattern = @DbName, 
        @command = '
    SELECT @@servername as ServerName,   db_name() AS DatabaseName,   
    CAST(f.size/128.0 AS decimal(20,2)) AS FileSize, 
    CASE
        WHEN mf.type_desc = ''FILESTREAM'' THEN CAST(f.size/128.0 AS decimal(20,2))
        ELSE CAST(FILEPROPERTY(mf.name, ''SpaceUsed'')/128.0 as decimal (20,2)) 
    END AS ''SpaceUsed'', 
    CASE 
        WHEN mf.type_desc = ''FILESTREAM'' THEN NULL
        WHEN mf.is_percent_growth = 0 
            THEN convert(varchar,ceiling((mf.growth * 8192.0)/(1024.0*1024.0)))  + '' MB'' 
        ELSE convert (varchar, mf.growth) + '' Percent'' 
    END AS FileGrowth, mf.name AS LogicalFileName, 
    mf.physical_name AS PhysicalFileName, mf.type_desc AS FileType,
    CAST(f.size/128.0 - CAST(FILEPROPERTY(mf.name, ''SpaceUsed'' ) AS int)/128.0 AS int) AS FreeSpaceMB,   
    CAST(100 * (CAST (((f.size/128.0 -CAST(FILEPROPERTY(mf.name,   
        ''SpaceUsed'' ) AS int)/128.0)/(f.size/128.0))   AS decimal(4,2))) AS varchar(8)) + ''%'' AS FreeSpacePct 
    FROM sys.master_files mf 
    JOIN sys.database_files f ON f.file_id = mf.file_id AND mf.database_id = db_id();
    ' ;
 

DECLARE @sql nvarchar(4000);
SET @sql = N'SELECT * FROM  #FileSizeInfo WHERE 1=1';

--Include optional filters
IF @IncludeDataFiles = 0
    SET @sql = @sql + N' AND FileType <> ''ROWS''';
IF @IncludeLogFiles = 0
    SET @sql = @sql + N' AND FileType <> ''LOG''';
IF @Drive IS NOT NULL
    SET @sql = @sql + N' AND PhysicalFileName LIKE ''' + @Drive + N'%''';

--include order by
SET @sql = @sql + N' ORDER BY ' + @OrderBy;

PRINT @sql;

EXEC sys.sp_executesql @sql;

GO


