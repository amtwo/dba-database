USE DBA
GO
--The CommandLog table comes from Ola's maintenance package.
--Table definition comes from there; These are indexes only.
--Compress the PK on Ola's table 
--Add a couple additional indexes to support querying the log. 
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'CommandLog')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.partitions
                WHERE object_id = object_id('CommandLog')
                AND data_compression_desc = 'NONE')
    BEGIN
        ALTER INDEX PK_CommandLog ON dbo.CommandLog
            REBUILD WITH (DATA_COMPRESSION=PAGE);
    END;

    IF NOT EXISTS (SELECT * FROM sys.indexes
                   WHERE object_id = object_id('CommandLog')
                   AND name = 'ix_CommandLog_CommandType_StartTime')
    BEGIN
        CREATE INDEX ix_CommandLog_CommandType_StartTime
            ON dbo.CommandLog (CommandType, StartTime)
            WITH (DATA_COMPRESSION=PAGE);
    END;

    IF NOT EXISTS (SELECT * FROM sys.indexes
                   WHERE object_id = object_id('CommandLog')
                   AND name = 'ix_CommandLog_StartTime')
    BEGIN
        CREATE INDEX ix_CommandLog_StartTime
            ON dbo.CommandLog (StartTime)
            WITH (DATA_COMPRESSION=PAGE);
    END;

END;

