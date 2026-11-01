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
        @DisplayNameSystemTypeId int,
        @DisplayNameMaxLength smallint,
        @DisplayNameTargetLength int,
        @AlterDisplayNameSql nvarchar(4000);

SELECT @DisplayNameNullable = is_nullable,
       @DisplayNameSystemTypeId = system_type_id,
       @DisplayNameMaxLength = max_length
FROM sys.columns
WHERE object_id = OBJECT_ID(N'dbo.TimeZones')
    AND name = N'DisplayName'
    AND user_type_id = system_type_id
    AND system_type_id IN (167, 175, 231, 239);

IF @DisplayNameSystemTypeId IS NOT NULL
BEGIN
    IF @DisplayNameSystemTypeId IN (167, 175)
    BEGIN
        SET @DisplayNameTargetLength = CASE
            WHEN @DisplayNameMaxLength = -1 OR @DisplayNameMaxLength > 4000 THEN -1
            WHEN @DisplayNameMaxLength < 128 THEN 128
            ELSE @DisplayNameMaxLength
        END;
    END
    ELSE
    BEGIN
        SET @DisplayNameTargetLength = CASE
            WHEN @DisplayNameMaxLength = -1 THEN -1
            WHEN @DisplayNameMaxLength / 2 < 128 THEN 128
            ELSE @DisplayNameMaxLength / 2
        END;
    END;

    IF @DisplayNameSystemTypeId <> 231
        OR @DisplayNameMaxLength BETWEEN 1 AND 255
    BEGIN
        SET @AlterDisplayNameSql = N'ALTER TABLE dbo.TimeZones ALTER COLUMN DisplayName nvarchar('
            + CASE
                WHEN @DisplayNameTargetLength = -1 THEN N'max'
                ELSE CONVERT(nvarchar(10), @DisplayNameTargetLength)
            END
            + N') '
            + CASE WHEN @DisplayNameNullable = 1 THEN N'NULL;' ELSE N'NOT NULL;' END;

        EXEC sys.sp_executesql @AlterDisplayNameSql;
    END;
END;



