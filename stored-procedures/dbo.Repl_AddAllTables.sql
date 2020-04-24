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
* The @ExcludeTables parameter requires the value be a comma-separated, single-quoted list.
    That's kind of icky, but we can make this more robust in v 2.0.  I don't think I'll use this exclude list very often
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

CREATE TABLE #article (
    ID int identity(1,1) PRIMARY KEY,
    ArticleName nvarchar(256));

--Get all unpublished tables that have a PK
SET @sql = N'SELECT t.name
        FROM [' + @PubDbName + '].sys.objects t
        JOIN [' + @PubDbName + '].sys.objects pk ON pk.parent_object_id = t.object_id
        WHERE t.is_ms_shipped = 0
        AND t.is_published = 0
        AND t.name NOT IN (' + COALESCE(@ExcludeTables,'''''') + ')
        AND t.type = ''U'';';

INSERT INTO #article
EXEC sp_executesql @sql;

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

DROP TABLE #article
GO


