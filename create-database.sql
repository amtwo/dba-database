-- SQLCMD substitutes text into a SQL literal. Double apostrophes in DbName when supplying it directly.
DECLARE @InputDbName  nvarchar(max) = N'$(DbName)',
        @DbName       sysname,
        @QuotedDbName nvarchar(258),
        @FileStem     nvarchar(129),
        @FilePath     nvarchar(4000),
        @Sql          nvarchar(max);

IF DATALENGTH(@InputDbName) > 256 OR LEN(@InputDbName) = 0
BEGIN
    RAISERROR('DbName must be a nonempty SQL Server identifier of at most 128 UTF-16 code units.', 16, 1);
    RETURN;
END;

SET @DbName = @InputDbName;

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @DbName)
BEGIN
    SET @QuotedDbName = QUOTENAME(@DbName);
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

    -- DOS device names are reserved even when followed by an extension.
    DECLARE @FirstComponent nvarchar(128) = RTRIM(LEFT(@FileStem, CHARINDEX(N'.', @FileStem + N'.') - 1));

    IF UPPER(@FirstComponent) COLLATE Latin1_General_100_BIN2 IN (N'CON', N'PRN', N'AUX', N'NUL')
       OR UPPER(@FirstComponent) COLLATE Latin1_General_100_BIN2 LIKE N'COM[1-9¹²³]'
       OR UPPER(@FirstComponent) COLLATE Latin1_General_100_BIN2 LIKE N'LPT[1-9¹²³]'
        SET @FileStem = N'_' + @FileStem;

    SET @Sql = N'CREATE DATABASE ' + @QuotedDbName;

    -- SQL Server uses the database name for default physical filenames.
    IF @FileStem COLLATE Latin1_General_100_BIN2 <> @DbName COLLATE Latin1_General_100_BIN2
       OR DATALENGTH(@DbName) > 246
    BEGIN
        DECLARE @DefaultDataPath nvarchar(4000) = CONVERT(nvarchar(4000), SERVERPROPERTY(N'InstanceDefaultDataPath')),
                @DefaultLogPath  nvarchar(4000) = CONVERT(nvarchar(4000), SERVERPROPERTY(N'InstanceDefaultLogPath'));

        IF RIGHT(@DefaultDataPath, 1) <> N'\'
            SET @DefaultDataPath += N'\';
        IF RIGHT(@DefaultLogPath, 1) <> N'\'
            SET @DefaultLogPath += N'\';

        SET @Sql += N' ON PRIMARY (NAME = [DB_Primary], FILENAME = N'''
                 + REPLACE(@DefaultDataPath + @FileStem + N'.mdf', N'''', N'''''') + N''')
LOG ON (NAME = [DB_Log], FILENAME = N'''
                 + REPLACE(@DefaultLogPath + @FileStem + N'_log.ldf', N'''', N'''''') + N''')';
    END;

    EXEC sys.sp_executesql @Sql;

    SELECT @FilePath = LEFT(physical_name, LEN(physical_name) - CHARINDEX(N'\', REVERSE(physical_name)) + 1)
                     + @FileStem + N'_data.ndf'
    FROM sys.master_files
    WHERE database_id = DB_ID(@DbName)
      AND file_id = 1;

    DECLARE @LogicalDataName sysname = CASE WHEN DATALENGTH(@DbName) <= 246
                                           THEN @DbName + N'_data'
                                           ELSE N'DB_Secondary' END;

    SET @Sql = N'ALTER DATABASE ' + @QuotedDbName + N' ADD FILEGROUP [DATA];
ALTER DATABASE ' + @QuotedDbName + N' ADD FILE (
    NAME = ' + QUOTENAME(@LogicalDataName) + N',
    FILENAME = N''' + REPLACE(@FilePath, N'''', N'''''') + N'''
) TO FILEGROUP [DATA];
ALTER DATABASE ' + @QuotedDbName + N' MODIFY FILEGROUP [DATA] DEFAULT;
ALTER DATABASE ' + @QuotedDbName + N' SET READ_COMMITTED_SNAPSHOT ON;
ALTER AUTHORIZATION ON DATABASE::' + @QuotedDbName + N' TO [sa];
ALTER DATABASE ' + @QuotedDbName + N' SET RECOVERY SIMPLE;';
    EXEC sys.sp_executesql @Sql;
END;
GO
