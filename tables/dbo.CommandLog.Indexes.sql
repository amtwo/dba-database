--The CommandLog table comes from Ola's maintenance package.
--Table definition comes from there; These are indexes only.
--Add a couple additional indexes to support querying the log. 
IF EXISTS (SELECT 1 FROM sys.objects WHERE object_id = object_id('dbo.CommandLog'))
BEGIN
    IF NOT EXISTS (SELECT * FROM sys.indexes
                   WHERE object_id = object_id('dbo.CommandLog')
                   AND name = 'ix_CommandLog_CommandType_StartTime')
    BEGIN
        CREATE INDEX ix_CommandLog_CommandType_StartTime
            ON dbo.CommandLog (CommandType, StartTime);
    END;

    IF NOT EXISTS (SELECT * FROM sys.indexes
                   WHERE object_id = object_id('dbo.CommandLog')
                   AND name = 'ix_CommandLog_StartTime')
    BEGIN
        CREATE INDEX ix_CommandLog_StartTime
            ON dbo.CommandLog (StartTime);
    END;

END;

DECLARE @version_chr varchar(10) = CAST(SERVERPROPERTY('ProductVersion') as varchar(10))
DECLARE @version_num int =  SUBSTRING(@version_chr,1,CHARINDEX('.',@version_chr,0)-1)
--Compress the PK on Ola's table + custom indexes, if the version/edition supports it
IF EXISTS (SELECT 1 
           WHERE SERVERPROPERTY('EngineEdition') NOT IN (2,4) --Compresion was enterprise only back in the day
               OR (@version_num = 13 AND SERVERPROPERTY('EngineEdition') = N'RTM') -- With 2016, everything but RTM supports compression
               OR (@version_num >= 14) -- 2017+, everyone supports compression
          )
BEGIN
    IF EXISTS (SELECT 1 FROM sys.partitions
                WHERE object_id = object_id('dbo.CommandLog')
                AND data_compression_desc = 'NONE')
    BEGIN
        ALTER INDEX PK_CommandLog ON dbo.CommandLog
            REBUILD WITH (DATA_COMPRESSION=PAGE);
    END;

    IF EXISTS (SELECT 1 FROM sys.partitions p
               JOIN sys.indexes i ON i.object_id = p.object_id AND i.index_id = p.index_id
               WHERE p.object_id = object_id('dbo.CommandLog')
               AND i.name = 'ix_CommandLog_CommandType_StartTime'
               AND p.data_compression_desc = 'NONE')
    BEGIN
        ALTER INDEX ix_CommandLog_CommandType_StartTime ON dbo.CommandLog
            REBUILD WITH (DATA_COMPRESSION=PAGE); 
    END;
    
    IF EXISTS (SELECT 1 FROM sys.partitions p
               JOIN sys.indexes i ON i.object_id = p.object_id AND i.index_id = p.index_id
               WHERE p.object_id = object_id('dbo.CommandLog')
               AND i.name = 'ix_CommandLog_StartTime'
               AND p.data_compression_desc = 'NONE')
    BEGIN
        ALTER INDEX ix_CommandLog_StartTime ON dbo.CommandLog
            REBUILD WITH (DATA_COMPRESSION=PAGE); 
    END;

END;
