CREATE OR ALTER PROCEDURE dbo.Check_QueryStore_TextSearch
    @DbNamePattern    nvarchar(300)     = NULL,
    @DatabaseList     nvarchar(max)     = NULL,
    @DbExcludePattern nvarchar(300)     = NULL,
    @DbExcludeList    nvarchar(max)     = NULL,
    @SearchText       nvarchar(4000)    = NULL,
    @SearchTextNot    nvarchar(4000)    = NULL,
    @WindowStart      datetimeoffset(7) = NULL,
    @WindowEnd        datetimeoffset(7) = NULL,
    @SortOrder        varchar(50)       = 'cpu',
    @Top              bigint            = 10,
    @EscapeBrackets   bit               = 0,
    @QueryType        varchar(11)       = NULL,
    @ExpertMode       bit               = 0,
    @Debug            bit               = 0
AS
/*************************************************************************************************
AUTHOR: Cody 🤖
DESCRIPTION
    Searches Query Store query text by calling sp_QuickieStore for each database selected by
    dbo.sp_ineachdb. QuickieStore applies its supported text-search filters and returns the
    requested sort metric and detail level.

PARAMETERS
    See sp_QuickieStore for query text, date window, sort order, query type, and expert mode details.
    Database selection parameters are passed to dbo.sp_ineachdb.

EXAMPLES:
-- Search all eligible databases for query text containing a string:
-- EXEC dbo.Check_QueryStore_TextSearch @SearchText = N'CustomerId';

-- Search selected databases, exclude a text pattern, and show additional detail:
-- EXEC dbo.Check_QueryStore_TextSearch
--     @DbNamePattern = N'AM%',
--     @SearchText = N'Orders',
--     @SearchTextNot = N'Archive',
--     @SortOrder = 'total cpu',
--     @ExpertMode = 1;
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
**************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1
        FROM sys.procedures AS p
        JOIN sys.schemas AS s
            ON s.schema_id = p.schema_id
        WHERE s.name = N'dbo'
          AND p.name = N'sp_QuickieStore'
    )
    BEGIN
        RAISERROR('sp_QuickieStore is not installed in the current utility database.', 16, 1);
        RETURN;
    END;

    DECLARE @Command nvarchar(max) = N'DECLARE @DbName sysname = DB_NAME();
EXEC ' + QUOTENAME(DB_NAME()) + N'.dbo.sp_QuickieStore'
        + N' @database_name = @DbName'
        + N', @query_text_search = ' + CASE WHEN @SearchText IS NULL THEN N'NULL'
            ELSE N'N''' + REPLACE(@SearchText, N'''', N'''''') + N'''' END
        + N', @query_text_search_not = ' + CASE WHEN @SearchTextNot IS NULL THEN N'NULL'
            ELSE N'N''' + REPLACE(@SearchTextNot, N'''', N'''''') + N'''' END
        + N', @start_date = ' + COALESCE(QUOTENAME(CONVERT(nvarchar(35), @WindowStart, 127), ''''), N'NULL')
        + N', @end_date = ' + COALESCE(QUOTENAME(CONVERT(nvarchar(35), @WindowEnd, 127), ''''), N'NULL')
        + N', @sort_order = ' + QUOTENAME(@SortOrder, '''')
        + N', @top = ' + CONVERT(nvarchar(20), @Top)
        + N', @escape_brackets = ' + CONVERT(nvarchar(1), @EscapeBrackets)
        + N', @query_type = ' + COALESCE(QUOTENAME(@QueryType, ''''), N'NULL')
        + N', @expert_mode = ' + CONVERT(nvarchar(1), @ExpertMode)
        + N', @hide_help_table = 1;';

    IF @Debug = 1
        EXEC dbo.Debug_Print @DebugMessage = @Command;

    EXEC dbo.sp_ineachdb
        @command         = @Command,
        @name_pattern    = @DbNamePattern,
        @database_list   = @DatabaseList,
        @exclude_pattern = @DbExcludePattern,
        @exclude_list    = @DbExcludeList;
END;
GO
