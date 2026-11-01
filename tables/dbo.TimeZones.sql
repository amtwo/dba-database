IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = object_id('dbo.TimeZones'))
BEGIN
    CREATE TABLE dbo.TimeZones (
        TimeZoneId      nvarchar(64),
        DisplayName     nvarchar(128),
        StandardName    nvarchar(64),
        DaylightName    nvarchar(64),
        SupportsDaylightSavingTime bit,
        CONSTRAINT PK_TimeZones PRIMARY KEY CLUSTERED (TimeZoneId)
        );
END;

IF (SELECT max_length FROM sys.columns WHERE object_id = object_id('dbo.TimeZones')) <256 /*data length =2x*/
ALTER TABLE dbo.TimeZones 
    ALTER COLUMN DisplayName nvarchar(128);



