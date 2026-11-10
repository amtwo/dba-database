IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Check_DriveSpace'))
    EXEC ('CREATE PROCEDURE dbo.Check_DriveSpace AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Check_DriveSpace
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20141001
    This procedure checks all drives that contain data files for available space.
    
PARAMETERS
* None
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDDD - Initials - Description of changes
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;
DECLARE @database_id int,
        @file_id int;

--Temp tables
CREATE TABLE #FileStats (
    database_id int,
    file_id int,
    volume_mount_point nvarchar(512),
    file_system_type nvarchar(512),
    total_bytes bigint,
    available_bytes bigint
    );

CREATE TABLE #Drives (
    volume_mount_point nvarchar(512),
    file_system_type nvarchar(512),
    total_GB numeric(10,3),
    available_GB numeric(10,3),
    available_percent numeric(5,2)
    );

--Cursors
DECLARE filestats_cur CURSOR FOR
    SELECT database_id, file_id
    FROM sys.master_files;

--Get filestats drive info for every datafile to get every drive
--just in case there's a mountpoint that isn't a drive
    
OPEN filestats_cur;
FETCH NEXT FROM filestats_cur INTO @database_id, @file_id;

WHILE @@FETCH_STATUS = 0
BEGIN
    INSERT INTO #FileStats (database_id, file_id, volume_mount_point, file_system_type, total_bytes, available_bytes)
    SELECT database_id, file_id, volume_mount_point, file_system_type, total_bytes, available_bytes
    FROM sys.dm_os_volume_stats (@database_id,@file_id);

    FETCH NEXT FROM filestats_cur INTO @database_id, @file_id;
END
CLOSE filestats_cur;
DEALLOCATE filestats_cur;

--dedupe info to get drive info
INSERT INTO #Drives (volume_mount_point, file_system_type, total_GB, available_GB, available_percent)
SELECT fs.volume_mount_point,
       fs.file_system_type,
       MIN(fs.total_bytes) / 1073741824.0,
       MIN(fs.available_bytes) / 1073741824.0,
       100.0 * MIN(fs.available_bytes) / NULLIF(MIN(fs.total_bytes), 0)
FROM #FileStats AS fs
GROUP BY fs.volume_mount_point, fs.file_system_type;

SELECT d.volume_mount_point, d.file_system_type, d.total_GB, d.available_GB, d.available_percent
FROM #Drives AS d;
GO
