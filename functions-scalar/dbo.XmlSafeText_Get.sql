/*************************************************************************************************
AUTHOR: Contributor
CREATED: 20261101
    Replaces characters that XML 1.0 cannot represent with U+FFFD.
    Valid XML characters, including valid supplementary characters, are preserved.

PARAMETERS
* @Text - Input text to make safe for XML serialization. NULL returns NULL.

EXAMPLES:
SELECT dbo.XmlSafeText_Get(N'Valid text');
SELECT dbo.XmlSafeText_Get(NCHAR(1)); -- Returns U+FFFD

**************************************************************************************************
MODIFICATIONS:
    20261101 - AM2 - Add reusable XML-safe text conversion.
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
CREATE OR ALTER FUNCTION dbo.XmlSafeText_Get
(
    @Text nvarchar(max)
)
RETURNS nvarchar(max)
AS
BEGIN
    IF @Text IS NULL
    BEGIN
        RETURN NULL;
    END;

    DECLARE @CodeUnitText nvarchar(max) = @Text,
            @TextBytes varbinary(max) = CONVERT(varbinary(max), @Text),
            @SafeText nvarchar(max),
            @Position int = 1,
            @SegmentStart int = 1,
            @Length int = DATALENGTH(@Text) / 2,
            @CharacterCode int,
            @NextCharacterCode int,
            @ReplaceCharacter bit,
            @NulSearchPosition int,
            @HasNul bit = 0,
            @SpecialSearchPosition int,
            @ChunkStart int = 1,
            @SearchChunk nvarchar(4000),
            @HasUnpairedSurrogate bit = 0,
            @HasNoncharacter bit = 0,
            @UnpairedHighSurrogatePattern nvarchar(100) = N'%[' + NCHAR(55296) + N'-' + NCHAR(56319)
                + N'][^' + NCHAR(56320) + N'-' + NCHAR(57343) + N']%',
            @TrailingHighSurrogatePattern nvarchar(100) = N'%[' + NCHAR(55296) + N'-' + NCHAR(56319) + N']',
            @InitialLowSurrogatePattern nvarchar(100) = N'[' + NCHAR(56320) + N'-' + NCHAR(57343) + N']%',
            @UnpairedLowSurrogatePattern nvarchar(100) = N'%[^' + NCHAR(55296) + N'-' + NCHAR(56319)
                + N'][' + NCHAR(56320) + N'-' + NCHAR(57343) + N']%';
    -- CHARINDEX uses binary data to find NUL, which cannot appear in a character search pattern.
    SET @NulSearchPosition = CHARINDEX(0x0000, @TextBytes, 1);

    WHILE @NulSearchPosition > 0
    BEGIN
        IF UNICODE(SUBSTRING(@CodeUnitText COLLATE Latin1_General_100_BIN2, (@NulSearchPosition / 2) + 1, 1)) = 0
        BEGIN
            SET @HasNul = 1;
            BREAK;
        END;

        SET @NulSearchPosition = CHARINDEX(0x0000, @TextBytes, @NulSearchPosition + 1);
    END;

    -- CHARINDEX on nvarchar can miss embedded U+FFFE/U+FFFF, so search the UTF-16 bytes
    -- and verify that each candidate starts on a code-unit boundary.
    SET @SpecialSearchPosition = CHARINDEX(0xFEFF, @TextBytes, 1);

    WHILE @SpecialSearchPosition > 0
    BEGIN
        IF @SpecialSearchPosition % 2 = 1
           AND UNICODE(SUBSTRING(@CodeUnitText COLLATE Latin1_General_100_BIN2, (@SpecialSearchPosition + 1) / 2, 1)) = 65534
        BEGIN
            SET @HasNoncharacter = 1;
            BREAK;
        END;

        SET @SpecialSearchPosition = CHARINDEX(0xFEFF, @TextBytes, @SpecialSearchPosition + 1);
    END;

    IF @HasNoncharacter = 0
    BEGIN
        SET @SpecialSearchPosition = CHARINDEX(0xFFFF, @TextBytes, 1);

        WHILE @SpecialSearchPosition > 0
        BEGIN
            IF @SpecialSearchPosition % 2 = 1
               AND UNICODE(SUBSTRING(@CodeUnitText COLLATE Latin1_General_100_BIN2, (@SpecialSearchPosition + 1) / 2, 1)) = 65535
            BEGIN
                SET @HasNoncharacter = 1;
                BREAK;
            END;

            SET @SpecialSearchPosition = CHARINDEX(0xFFFF, @TextBytes, @SpecialSearchPosition + 1);
        END;
    END;

    -- PATINDEX does not reliably scan nvarchar(max) surrogate patterns. Search
    -- bounded nvarchar chunks, overlapping by one code unit so every pair is seen.
    WHILE @ChunkStart <= @Length AND @HasUnpairedSurrogate = 0
    BEGIN
        SET @SearchChunk = SUBSTRING(@CodeUnitText COLLATE Latin1_General_100_BIN2, @ChunkStart, 4000);

        IF PATINDEX(@UnpairedHighSurrogatePattern, @SearchChunk COLLATE Latin1_General_100_BIN2) > 0
           OR PATINDEX(@TrailingHighSurrogatePattern, @SearchChunk COLLATE Latin1_General_100_BIN2) > 0
           OR PATINDEX(@InitialLowSurrogatePattern, @SearchChunk COLLATE Latin1_General_100_BIN2) > 0
           OR PATINDEX(@UnpairedLowSurrogatePattern, @SearchChunk COLLATE Latin1_General_100_BIN2) > 0
        BEGIN
            SET @HasUnpairedSurrogate = 1;
        END;

        SET @ChunkStart += 3999;
    END;

    -- Native searches handle valid text; only scan and rebuild if invalid code points exist.
    IF @HasNul = 0
       AND PATINDEX(N'%[' + NCHAR(1) + N'-' + NCHAR(8) + NCHAR(11) + NCHAR(12)
                    + NCHAR(14) + N'-' + NCHAR(31) + N']%', @Text) = 0
       AND @HasNoncharacter = 0
       AND @HasUnpairedSurrogate = 0
    BEGIN
        RETURN @Text;
    END;
    WHILE @Position <= @Length
    BEGIN
        SET @CharacterCode = UNICODE(SUBSTRING(@CodeUnitText COLLATE Latin1_General_100_BIN2, @Position, 1));
        SET @ReplaceCharacter = 0;

        IF @CharacterCode BETWEEN 55296 AND 56319 -- High surrogate
        BEGIN
            IF @Position < @Length
            BEGIN
                SET @NextCharacterCode = UNICODE(SUBSTRING(@CodeUnitText COLLATE Latin1_General_100_BIN2, @Position + 1, 1));

                IF @NextCharacterCode BETWEEN 56320 AND 57343 -- Valid low surrogate
                BEGIN
                    SET @Position += 2;
                END
                ELSE
                BEGIN
                    SET @ReplaceCharacter = 1;
                END;
            END;
            ELSE
            BEGIN
                SET @ReplaceCharacter = 1;
            END;
        END;
        ELSE
        BEGIN
            IF @CharacterCode BETWEEN 56320 AND 57343 -- Unpaired low surrogate
            BEGIN
                SET @ReplaceCharacter = 1;
            END
            ELSE
            BEGIN
                IF @CharacterCode NOT IN (9, 10, 13)
                     AND @CharacterCode NOT BETWEEN 32 AND 55295
                     AND @CharacterCode NOT BETWEEN 57344 AND 65533
                BEGIN
                    SET @ReplaceCharacter = 1;
                END
                ELSE
                BEGIN
                    SET @Position += 1;
                END;
            END;
        END;

        IF @ReplaceCharacter = 1
        BEGIN
            IF @SafeText IS NULL
            BEGIN
                SET @SafeText = N'';
            END;

            IF @Position > @SegmentStart
            BEGIN
                SET @SafeText += SUBSTRING(@CodeUnitText COLLATE Latin1_General_100_BIN2, @SegmentStart, @Position - @SegmentStart);
            END;

            SET @SafeText += NCHAR(65533);
            SET @Position += 1;
            SET @SegmentStart = @Position;
        END;
    END;

    IF @SafeText IS NULL
    BEGIN
        RETURN @Text;
    END;

    RETURN @SafeText + SUBSTRING(@CodeUnitText COLLATE Latin1_General_100_BIN2, @SegmentStart, @Length - @SegmentStart + 1);
END;
GO
