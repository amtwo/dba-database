CREATE OR ALTER PROCEDURE dbo.Check_QueryStore_TopIoDelta
    @DbNamePattern      nvarchar(300)     = NULL,
    @DatabaseList       nvarchar(max)     = NULL,
    @DbExcludePattern   nvarchar(300)     = NULL,
    @DbExcludeList      nvarchar(max)     = NULL,
    @WindowStart        datetimeoffset(7) = NULL,
    @WindowEnd          datetimeoffset(7) = NULL,
    @CompareOffsetHours int               = 168,
    @Top                int               = 25,
    @Debug              bit               = 0
AS
/*************************************************************************************************
AUTHOR: Cody 🤖
DESCRIPTION
    Runs dbo.QueryStore_TopIoDelta for each database selected by dbo.sp_ineachdb.

PARAMETERS
    See dbo.QueryStore_TopIoDelta for parameter descriptions.

**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
**************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    DECLARE @Command nvarchar(max) = N'DECLARE @DbName sysname = DB_NAME();
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @DbName AND is_query_store_on = 1)
BEGIN
    EXEC ' + QUOTENAME(DB_NAME()) + N'.dbo.QueryStore_TopIoDelta'
        + N' @DatabaseName = @DbName'
        + N', @WindowStart        = ' + COALESCE(QUOTENAME(CONVERT(nvarchar(35), @WindowStart, 127), ''''), N'NULL')
        + N', @WindowEnd          = ' + COALESCE(QUOTENAME(CONVERT(nvarchar(35), @WindowEnd, 127), ''''), N'NULL')
        + N', @CompareOffsetHours = ' + CONVERT(nvarchar(12), @CompareOffsetHours)
        + N', @Top                = ' + CONVERT(nvarchar(12), @Top)
        + N', @Debug              = ' + CONVERT(nvarchar(1), @Debug) + N';
END;';

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
