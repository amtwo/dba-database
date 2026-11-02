CREATE OR ALTER PROCEDURE dbo.Check_QueryStore_GuardrailState
    @DbNamePattern      nvarchar(300)     = NULL,
    @DatabaseList       nvarchar(max)     = NULL,
    @DbExcludePattern   nvarchar(300)     = NULL,
    @DbExcludeList      nvarchar(max)     = NULL,
    @QueryHashes        nvarchar(max)     = NULL,
    @ActiveDays         int               = 3,
    @Debug              bit               = 0
AS
/*************************************************************************************************
AUTHOR: Cody 🤖
DESCRIPTION
    Runs dbo.QueryStore_GuardrailState for each database selected by dbo.sp_ineachdb.

PARAMETERS
    See dbo.QueryStore_GuardrailState for parameter descriptions.

    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
**************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    DECLARE @Command nvarchar(max) = N'DECLARE @DbName sysname = DB_NAME();
EXEC ' + QUOTENAME(DB_NAME()) + N'.dbo.QueryStore_GuardrailState'
        + N' @DatabaseName = @DbName'
        + N', @QueryHashes = ' + COALESCE(N'''' + REPLACE(@QueryHashes, N'''', N'''''') + N'''', N'NULL')
        + N', @ActiveDays  = ' + CONVERT(nvarchar(12), @ActiveDays)
        + N', @Debug       = ' + CONVERT(nvarchar(1), @Debug) + N';';

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
