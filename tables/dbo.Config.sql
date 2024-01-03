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

IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'EMAILBOLDCOLOR')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, UnicodeValue)
    VALUES ('EMAILBOLDCOLOR', 'Alerting', 'Email Bold Color', '#032E57')
END;

IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'EMAILALERTCOLOR')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, UnicodeValue)
    VALUES ('EMAILALERTCOLOR', 'Alerting', 'Email Alert Color', '#DC080A')
END;

IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'EMAILBGCOLOR')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, UnicodeValue)
    VALUES ('EMAILBGCOLOR', 'Alerting', 'Email Background Color', '#D0CAC4')
END;

IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'EMAILBGCOLOR2')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, UnicodeValue)
    VALUES ('EMAILBGCOLOR2', 'Alerting', 'Email Background Color (Alternate)', '#E4F1FE')
END;

IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'EMAILALRTBGCOLOR')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, UnicodeValue)
    VALUES ('EMAILALRTBGCOLOR', 'Alerting', 'Email Background Color Alert', '#FEF1E4')
END;

IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'EMAILALRTDOMAIN')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, UnicodeValue)
    VALUES ('EMAILALRTDOMAIN', 'Alerting', 'Email Sender Domain', 'example.com')
END;
