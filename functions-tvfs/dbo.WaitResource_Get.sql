CREATE OR ALTER FUNCTION dbo.WaitResource_Get
(
    @WaitResource nvarchar(256)
)
RETURNS TABLE
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20261101
    Parses supported SQL Server wait-resource strings into their database and resource identifiers.
    Object names are resolved with SQL Server metadata functions; index names and HoBT lookups that
    require cross-database catalog queries are resolved by the calling procedure.

PARAMETERS
* @WaitResource - Wait resource from sys.dm_exec_requests.

EXAMPLES:
SELECT * FROM dbo.WaitResource_Get(N'TAB: 5:261575970:1');
SELECT * FROM dbo.WaitResource_Get(N'OBJECT: 5:261575970:0');
SELECT * FROM dbo.WaitResource_Get(N'PAGE: 5:1:104');

**************************************************************************************************
MODIFICATIONS:
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
RETURN
    WITH Normalized AS
    (
        SELECT NormalizedResource = LTRIM(@WaitResource)
    ),
    Typed AS
    (
        SELECT
            NormalizedResource,
            ResourceType = CASE
                WHEN NormalizedResource LIKE 'KEY:%' THEN 'KEY'
                WHEN NormalizedResource LIKE 'OBJECT:%' THEN 'OBJECT'
                WHEN NormalizedResource LIKE 'TAB:%' THEN 'TAB'
                WHEN NormalizedResource LIKE 'PAGE:%' THEN 'PAGE'
                WHEN NormalizedResource LIKE 'RID:%' THEN 'RID'
            END,
            ResourceBody = CASE
                WHEN NormalizedResource LIKE 'KEY:%' THEN LTRIM(SUBSTRING(NormalizedResource, 5, 256))
                WHEN NormalizedResource LIKE 'OBJECT:%' THEN LTRIM(SUBSTRING(NormalizedResource, 8, 256))
                WHEN NormalizedResource LIKE 'TAB:%' THEN LTRIM(SUBSTRING(NormalizedResource, 5, 256))
                WHEN NormalizedResource LIKE 'PAGE:%' THEN LTRIM(SUBSTRING(NormalizedResource, 6, 256))
                WHEN NormalizedResource LIKE 'RID:%' THEN LTRIM(SUBSTRING(NormalizedResource, 5, 256))
            END
        FROM Normalized
    ),
    Parts AS
    (
        SELECT
            NormalizedResource,
            ResourceType,
            ResourceBody,
            ResourceParts = REPLACE(ResourceBody, ':', '.')
        FROM Typed
    ),
    Parsed AS
    (
        SELECT
            NormalizedResource,
            ResourceType,
            DatabaseId = TRY_CONVERT(int, CASE
                WHEN ResourceType = 'OBJECT' AND PARSENAME(ResourceParts, 3) IS NOT NULL
                    THEN PARSENAME(ResourceParts, 3)
                WHEN ResourceType IN ('KEY', 'OBJECT') THEN PARSENAME(ResourceParts, 2)
                WHEN ResourceType = 'TAB' AND PARSENAME(ResourceParts, 3) IS NULL
                    THEN PARSENAME(ResourceParts, 2)
                WHEN ResourceType = 'RID' THEN PARSENAME(ResourceParts, 4)
                ELSE PARSENAME(ResourceParts, 3)
            END),
            ObjectId = CASE WHEN ResourceType = 'OBJECT' THEN TRY_CONVERT(int, CASE
                                WHEN PARSENAME(ResourceParts, 3) IS NOT NULL THEN PARSENAME(ResourceParts, 2)
                                ELSE PARSENAME(ResourceParts, 1)
                            END)
                            WHEN ResourceType = 'TAB' THEN TRY_CONVERT(int, CASE
                                WHEN PARSENAME(ResourceParts, 3) IS NULL THEN PARSENAME(ResourceParts, 1)
                                ELSE PARSENAME(ResourceParts, 2)
                            END)
            END,
            IndexId = CASE WHEN ResourceType = 'TAB' AND PARSENAME(ResourceParts, 3) IS NOT NULL
                THEN TRY_CONVERT(int, PARSENAME(ResourceParts, 1)) END,
            HobtId = CASE WHEN ResourceType = 'KEY'
                THEN TRY_CONVERT(bigint, LEFT(
                    SUBSTRING(ResourceBody, CHARINDEX(':', ResourceBody) + 1, 256),
                    CHARINDEX(' ', SUBSTRING(ResourceBody, CHARINDEX(':', ResourceBody) + 1, 256) + ' ') - 1))
            END,
            FileId = CASE WHEN ResourceType = 'PAGE' THEN TRY_CONVERT(int, PARSENAME(ResourceParts, 2))
                          WHEN ResourceType = 'RID' THEN TRY_CONVERT(int, PARSENAME(ResourceParts, 3))
            END,
            PageId = CASE WHEN ResourceType = 'PAGE' THEN TRY_CONVERT(bigint, PARSENAME(ResourceParts, 1))
                          WHEN ResourceType = 'RID' THEN TRY_CONVERT(bigint, PARSENAME(ResourceParts, 2))
            END,
            SlotId = CASE WHEN ResourceType = 'RID' THEN TRY_CONVERT(int, PARSENAME(ResourceParts, 1)) END
        FROM Parts
    )
    SELECT
        RawResource = NormalizedResource,
        ResourceType,
        DatabaseId,
        DatabaseName = DB_NAME(DatabaseId),
        ObjectId,
        SchemaName = OBJECT_SCHEMA_NAME(ObjectId, DatabaseId),
        ObjectName = OBJECT_NAME(ObjectId, DatabaseId),
        IndexId,
        HobtId,
        FileId,
        FileName = masterFile.name,
        PageId,
        SlotId
    FROM Parsed
    LEFT JOIN sys.master_files masterFile
        ON masterFile.database_id = Parsed.DatabaseId
        AND masterFile.file_id = Parsed.FileId;
GO
