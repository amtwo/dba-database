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

    
/* There's a better way to manage this config data, but I'll handle the number of configs warrants it */

/*****************************************************************************
                            Replication Configs
*****************************************************************************/
IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'REPLSCMOPT')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, VarbinaryValue)
    VALUES ('REPLSCMOPT', 'Replication', 'Schema Option', 0x00000044080350DF)
END;

/*****************************************************************************
                            Email styling Configs
*****************************************************************************/
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

/*****************************************************************************
                            Update_Statistics Configs
These are BASELINE values that equal the proc's built-in fallbacks, so deploying them
changes no behavior on any server -- they exist so the policy is visible and editable as data.
Existence checks ensure that defaults are inserted if missing, but existing data is
never updated.
*****************************************************************************/

-- Medium row-count threshold: rows >= this are at least Medium.
IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'STATMEDROWS')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, NumericValue)
    VALUES ('STATMEDROWS', 'StatisticsMaint', 'Medium Row Count Threshold', 1000000)
END;

-- Large row-count threshold: rows >= this are Large. Must be >= the Medium threshold.
IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'STATLRGROWS')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, NumericValue)
    VALUES ('STATLRGROWS', 'StatisticsMaint', 'Large Row Count Threshold', 100000000)
END;

-- Small-bucket sample percent (100 = FULLSCAN).
IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'STATSMPSML')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, NumericValue)
    VALUES ('STATSMPSML', 'StatisticsMaint', 'Small Table Sample Percent', 100)
END;

-- Medium-bucket sample percent (100 = FULLSCAN).
IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'STATSMPMED')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, NumericValue)
    VALUES ('STATSMPMED', 'StatisticsMaint', 'Medium Table Sample Percent', 100)
END;

-- Large-bucket sample percent. Mobo policy will lower this to 50 (giants get a sample, not a scan).
IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'STATSMPLRG')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, NumericValue)
    VALUES ('STATSMPLRG', 'StatisticsMaint', 'Large Table Sample Percent', 50)
END;

-- Skew analysis on/off (0 = off; the alpha/experimental bucket-bump path).
IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'STATSKEW')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, NumericValue)
    VALUES ('STATSKEW', 'StatisticsMaint', 'Skew Analysis Enabled', 0)
END;

-- Skew ratio cutoff (max/avg histogram step ratio treated as skewed). Only used when skew is on.
IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'STATSKEWCUT')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, NumericValue)
    VALUES ('STATSKEWCUT', 'StatisticsMaint', 'Skew Ratio Cutoff', 100.00)
END;

-- Log every Ola command to dbo.CommandLog (1 = yes).
IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'STATLOGTBL')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, NumericValue)
    VALUES ('STATLOGTBL', 'StatisticsMaint', 'Log To Table', 1)
END;

-- Per-table override list. Seeded as an empty JSON array = "no exceptions"; the proc runs purely
-- size-driven. Populate per server with sparse exceptions, e.g.:
--   [ { "db": "MyDb", "schema": "dbo", "table": "%old",                 "exclude": true },
--     { "db": "MyDb", "schema": "dbo", "table": "StaticArchiveTable",   "exclude": true },
--     { "db": "MyDb", "schema": "dbo", "table": "BigTransactionsTable", "sample": 30 },
--     { "db": "MyDb", "schema": "dbo", "table": "SomeLookup",           "bucket": "Large" },
--     { "db": "MyDb", "schema": "dbo", "table": "HotVolatile",          "lock": true } ]
-- Each entry needs db/schema/table plus any of: "exclude" (bool), "sample" (1-100), "bucket",
-- "lock" (bool: true = force auto-stats OFF, false = force-exempt, overriding the size threshold).
-- "table" is matched with LIKE (so "%old" skips every table whose name ends in "old"); "schema" is
-- exact. An exact-name entry beats a wildcard for sample/bucket; exclude=true from any match wins.
-- LIKE wildcards apply: _ [ % are special, so a literal name with one must be bracket-escaped,
-- e.g. "Order[_]Detail" to match only that table and not "OrderXDetail".
IF NOT EXISTS (SELECT 1 FROM dbo.Config WHERE ConfigCode = 'STATOVERRIDE')
BEGIN
    INSERT INTO dbo.Config (ConfigCode, ConfigCategory, ConfigName, UnicodeValue)
    VALUES ('STATOVERRIDE', 'StatisticsMaint', 'Table Overrides', N'[]')
END;

-- NOTE: the two "never" knobs -- Disable AutoStats Threshold (STATLOCKROW) and Statistics
-- Modification Level (STATMODLVL) -- are intentionally NOT seeded. An absent row leaves the proc
-- parameter NULL (= feature off). Add the row on a server that wants locking / a modification
-- level



