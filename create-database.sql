--Create DB
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = '$(DbName)')
BEGIN
    CREATE DATABASE [$(DbName)];
    ALTER DATABASE  [$(DbName)] ADD FILEGROUP [DATA];
    --Need to use dynamic SQL to ensure we put this data file in the right spot dynamically
    DECLARE @sql nvarchar(max);
    SELECT @sql = N'ALTER DATABASE  [$(DbName)] ADD FILE (NAME=''$(DbName)_data'', FILENAME=''' 
                    + LEFT(physical_name,LEN(physical_name)-CHARINDEX('\',REVERSE(physical_name))+1) 
                    + N'$(DbName)_data.ndf' + N''') TO FILEGROUP [DATA];'
    FROM sys.master_files 
    WHERE database_id = db_id('$(DbName)')
    AND file_id = 1;
    EXEC sp_executesql @statement = @sql;
    --And now finish up creating it
    ALTER DATABASE  [$(DbName)] MODIFY FILEGROUP [DATA] DEFAULT;
    ALTER DATABASE  [$(DbName)] SET READ_COMMITTED_SNAPSHOT ON;
    --set sa as owner
    ALTER AUTHORIZATION ON database::$(DbName) TO sa;
    --set to simple recovery on creation
    --if you change this after creation, we won't change it back.
    ALTER DATABASE $(DbName) SET RECOVERY SIMPLE;
END
GO
