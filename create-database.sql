-- SQLCMD substitutes text into a SQL literal. Double apostrophes in DbName when supplying it directly.
DECLARE @DbName       sysname = N'$(DbName)',
        @QuotedDbName nvarchar(258),
        @FileStem     nvarchar(128),
        @FilePath     nvarchar(4000),
        @Sql          nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @DbName)
BEGIN
    SET @QuotedDbName = QUOTENAME(@DbName);
    SET @Sql = N'CREATE DATABASE ' + @QuotedDbName + N';';
    EXEC sys.sp_executesql @Sql;

    SET @FileStem = @DbName;

    -- Windows disallows these punctuation and control characters in filenames.
    DECLARE @Position int = 1,
            @Character nchar(1);

    WHILE @Position <= DATALENGTH(@FileStem) / 2
    BEGIN
        SET @Character = SUBSTRING(@FileStem COLLATE Latin1_General_100_BIN2, @Position, 1);
        IF UNICODE(@Character) < 32 OR CHARINDEX(@Character COLLATE Latin1_General_100_BIN2, N'<>:"/\|?*') > 0
            SET @FileStem = STUFF(@FileStem COLLATE Latin1_General_100_BIN2, @Position, 1, N'_');
        SET @Position += 1;
    END;

    SELECT @FilePath = LEFT(physical_name, LEN(physical_name) - CHARINDEX(N'\', REVERSE(physical_name)) + 1)
                     + @FileStem + N'_data.ndf'
    FROM sys.master_files
    WHERE database_id = DB_ID(@DbName)
      AND file_id = 1;

    SET @Sql = N'ALTER DATABASE ' + @QuotedDbName + N' ADD FILEGROUP [DATA];
ALTER DATABASE ' + @QuotedDbName + N' ADD FILE (
    NAME = ' + QUOTENAME(N'DBA_data') + N',
    FILENAME = N''' + REPLACE(@FilePath, N'''', N'''''') + N'''
) TO FILEGROUP [DATA];
ALTER DATABASE ' + @QuotedDbName + N' MODIFY FILEGROUP [DATA] DEFAULT;
ALTER DATABASE ' + @QuotedDbName + N' SET READ_COMMITTED_SNAPSHOT ON;
ALTER AUTHORIZATION ON DATABASE::' + @QuotedDbName + N' TO [sa];
ALTER DATABASE ' + @QuotedDbName + N' SET RECOVERY SIMPLE;';
    EXEC sys.sp_executesql @Sql;
END;
GO
