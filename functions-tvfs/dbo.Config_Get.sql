CREATE OR ALTER FUNCTION dbo.Config_Get
(
    @ConfigCategory varchar(128) = NULL,
    @ConfigCode     varchar(16)  = NULL
)
RETURNS TABLE
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260713
    Generic read accessor for the dbo.Config key-value table. Inline table-valued function so it
    inlines into the caller's plan (no per-row scalar-UDF penalty).

    Both parameters are optional and filter independently via COALESCE(@param, column):
    * Both NULL          -> every row in dbo.Config.
    * @ConfigCategory    -> every row in that category (e.g. read a whole feature's config in one go).
    * @ConfigCode        -> the single row for that key (ConfigCode is the PK).
    * Both supplied      -> the row matching both (a category-scoped key lookup).

PARAMETERS:
    @ConfigCategory - Optional ConfigCategory filter. NULL = any category.
    @ConfigCode     - Optional ConfigCode filter. NULL = any code.

EXAMPLES:
-- Read one setting:
-- SELECT NumericValue FROM dbo.Config_Get(NULL, 'STATSMPLRG');

-- Read every setting in a category in a single call:
-- SELECT * FROM dbo.Config_Get('StatisticsMaint', NULL);

-- Dump the whole table:
-- SELECT * FROM dbo.Config_Get(DEFAULT, DEFAULT);
**************************************************************************************************
MODIFICATIONS:
    20260713 - AM2 - Initial version.
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
RETURN
    SELECT
        ConfigCode,
        ConfigCategory,
        ConfigName,
        UnicodeValue,
        NumericValue,
        VarbinaryValue
    FROM dbo.Config
    WHERE ConfigCategory = COALESCE(@ConfigCategory, ConfigCategory)
      AND ConfigCode     = COALESCE(@ConfigCode,     ConfigCode);
GO
