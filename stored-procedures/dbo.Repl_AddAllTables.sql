IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Repl_AddAllTables'))
    EXEC ('CREATE PROCEDURE dbo.Repl_AddAllTables AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Repl_AddAllTables
    @PubDbName nvarchar(256),
    @PublicationName nvarchar(256),
    @ExcludeTables nvarchar(256) = NULL,
    @Debug bit = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20140101
    This procedure loops through all tables in the database and adds them to replication.
    Made this for a specific use case, so its not glamorous.
    
PARAMETERS
* @ExcludeTables - Optional comma-separated list of single-quoted table names to exclude.
                   Embedded single quotes must be doubled, following SQL string-literal syntax.
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDDD - Initials - Description of changes
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

DECLARE @sql nvarchar(max);
DECLARE @ArticleName nvarchar(256);
DECLARE @QuotedPubDbName nvarchar(258) = QUOTENAME(@PubDbName);
DECLARE @Position int = 1;
DECLARE @IsInsideQuote bit = 0;
DECLARE @CurrentChar nvarchar(2);
DECLARE @ExcludedTableName nvarchar(256) = N'';

IF @QuotedPubDbName IS NULL OR DB_ID(@PubDbName) IS NULL
BEGIN
    RAISERROR ('The specified publication database is invalid or unavailable.', 16, 1);
    RETURN -1;
END;

CREATE TABLE #ExcludedTables (
    ArticleName nvarchar(256) COLLATE DATABASE_DEFAULT
);

-- @ExcludeTables is a comma-separated list of SQL-style quoted table names.
-- Parse it as data so it can never become part of the executable SQL.
IF NULLIF(LTRIM(RTRIM(@ExcludeTables)), N'') IS NOT NULL
BEGIN
    WHILE @Position <= LEN(@ExcludeTables)
    BEGIN
        SET @CurrentChar = SUBSTRING(@ExcludeTables, @Position, 1);

        IF @CurrentChar = N''''
        BEGIN
            IF @IsInsideQuote = 1 AND SUBSTRING(@ExcludeTables, @Position + 1, 1) = N''''
            BEGIN
                SET @ExcludedTableName += N'''';
                SET @Position += 2;
                CONTINUE;
            END;

            SET @IsInsideQuote = CASE WHEN @IsInsideQuote = 1 THEN 0 ELSE 1 END;
        END
        ELSE IF @CurrentChar = N',' AND @IsInsideQuote = 0
        BEGIN
            IF @ExcludedTableName <> N''
                INSERT INTO #ExcludedTables (ArticleName) VALUES (@ExcludedTableName);

            SET @ExcludedTableName = N'';
        END
        ELSE IF @IsInsideQuote = 1
            SET @ExcludedTableName += @CurrentChar;
        ELSE IF @CurrentChar NOT IN (N' ', NCHAR(9), NCHAR(10), NCHAR(13))
        BEGIN
            RAISERROR ('@ExcludeTables must be a comma-separated list of single-quoted table names.', 16, 1);
            RETURN -1;
        END;

        SET @Position += 1;
    END;

    IF @IsInsideQuote = 1
    BEGIN
        RAISERROR ('@ExcludeTables contains an unclosed quoted table name.', 16, 1);
        RETURN -1;
    END;

    IF @ExcludedTableName <> N''
        INSERT INTO #ExcludedTables (ArticleName) VALUES (@ExcludedTableName);
END;

CREATE TABLE #article (
    ID int identity(1,1) PRIMARY KEY,
    ArticleName nvarchar(256));

--Get all unpublished tables that have a PK
SET @sql = N'USE ' + @QuotedPubDbName + N';
        SELECT t.name
        FROM sys.objects AS t
        JOIN sys.objects AS pk ON pk.parent_object_id = t.object_id
        WHERE t.is_ms_shipped = 0
        AND t.is_published = 0
        AND NOT EXISTS (SELECT 1
                        FROM #ExcludedTables AS excluded
                        WHERE excluded.ArticleName COLLATE DATABASE_DEFAULT = t.name COLLATE DATABASE_DEFAULT)
        AND t.type = ''U'';';

INSERT INTO #article
EXEC sys.sp_executesql @sql;

--Call Repl_AddArticle in a loop for every table in #article
--Debug mode works by passing parameter through to Repl_AddArticle to print statement

DECLARE article_cur CURSOR FOR
    SELECT DISTINCT ArticleName FROM #article;

OPEN article_cur;
FETCH NEXT FROM article_cur INTO @ArticleName;

WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.Repl_AddArticle 
        @PubDbName = @PubDbName,
        @PublicationName = @PublicationName,
        @ArticleName = @ArticleName,
        @Debug = @Debug
    FETCH NEXT FROM article_cur INTO @ArticleName;
END;

CLOSE article_cur;
DEALLOCATE article_cur;

DROP TABLE #article;
GO


