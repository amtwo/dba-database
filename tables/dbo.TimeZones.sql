IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = object_id('dbo.TimeZones'))
BEGIN
    CREATE TABLE dbo.TimeZones (
        TimeZoneId      nvarchar(64),
        DisplayName     nvarchar(64),
        StandardName    nvarchar(64),
        DaylightName    nvarchar(64),
        SupportsDaylightSavingTime bit,
        CONSTRAINT PK_TimeZones PRIMARY KEY CLUSTERED (TimeZoneId)
        );
END;


