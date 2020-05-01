--dbo.Config
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = object_id('dbo.Config'))
BEGIN
    CREATE TABLE dbo.Config(
        ConfigCode          varchar(16) NOT NULL,
        ConfigCategory      varchar(128) NOT NULL,
        ConfigName          varchar(128) NOT NULL,
        UnicodeValue        nvarchar(max) NULL,
        NumericValue        numeric(16,6) NULL,
        VarbinaryValue      varbinary(max) NULL,
        CONSTRAINT PK_Config PRIMARY KEY CLUSTERED (ConfigCode),
        CONSTRAINT UIX_Category_Name UNIQUE NONCLUSTERED (ConfigCategory,ConfigName),
        -- Make sure at most one value is specified
        CONSTRAINT CK_Config_Values
            CHECK(
                    ( CASE WHEN UnicodeValue    IS NULL THEN 0 ELSE 1 END
                    + CASE WHEN NumericValue    IS NULL THEN 0 ELSE 1 END
                    + CASE WHEN VarbinaryValue  IS NULL THEN 0 ELSE 1 END
                    ) <= 1
                 )
    ) ON [DATA];
END
GO


-- There's a better way to manage this config data, but I'll handle the number of configs warrants it
IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'REPLSCMOPT')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, VarbinaryValue)
    VALUES ('REPLSCMOPT', 'Replication', 'Schema Option', 0x00000044080350DF)
END;