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

DECLARE @DisplayNameNullable bit,
        @AlterDisplayNameSql nvarchar(4000);

SELECT @DisplayNameNullable = is_nullable
FROM sys.columns
WHERE object_id = OBJECT_ID(N'dbo.TimeZones')
    AND name = N'DisplayName'
    AND max_length BETWEEN 1 AND 255;

IF @DisplayNameNullable IS NOT NULL
BEGIN
    SET @AlterDisplayNameSql = N'ALTER TABLE dbo.TimeZones ALTER COLUMN DisplayName nvarchar(128) '
        + CASE WHEN @DisplayNameNullable = 1 THEN N'NULL;' ELSE N'NOT NULL;' END;

    EXEC sys.sp_executesql @AlterDisplayNameSql;
END;


