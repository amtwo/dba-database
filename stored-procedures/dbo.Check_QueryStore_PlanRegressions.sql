CREATE OR ALTER PROCEDURE dbo.Check_QueryStore_PlanRegressions
    @DbNamePattern      nvarchar(300)     = NULL,
    @DatabaseList       nvarchar(max)     = NULL,
    @DbExcludePattern   nvarchar(300)     = NULL,
    @DbExcludeList      nvarchar(max)     = NULL,
    @WindowStart        datetimeoffset(7) = NULL,
    @WindowEnd          datetimeoffset(7) = NULL,
    @MinExecs           bigint            = 50,
    @MinCpuRatio        decimal(9, 2)     = 2.0,
    @Debug              bit               = 0
AS
/*************************************************************************************************
AUTHOR: Cody 🤖
DESCRIPTION
    Runs dbo.QueryStore_PlanRegressions for each database selected by DBA.dbo.sp_ineachdb.

PARAMETERS
    See dbo.QueryStore_PlanRegressions for parameter descriptions.

**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
**************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    DECLARE @Command nvarchar(max) = N'EXEC DBA.dbo.QueryStore_PlanRegressions'
        + N' @DatabaseName = DB_NAME()'
        + N', @WindowStart = ' + COALESCE(QUOTENAME(CONVERT(nvarchar(35), @WindowStart, 127), ''''), N'NULL')
        + N', @WindowEnd   = ' + COALESCE(QUOTENAME(CONVERT(nvarchar(35), @WindowEnd, 127), ''''), N'NULL')
        + N', @MinExecs    = ' + CONVERT(nvarchar(20), @MinExecs)
        + N', @MinCpuRatio = ' + CONVERT(nvarchar(30), @MinCpuRatio)
        + N', @Debug       = ' + CONVERT(nvarchar(1), @Debug) + N';';

    IF @Debug = 1
        EXEC dbo.Debug_Print @DebugMessage = @Command;

    EXEC DBA.dbo.sp_ineachdb
        @command         = @Command,
        @name_pattern    = @DbNamePattern,
        @database_list   = @DatabaseList,
        @exclude_pattern = @DbExcludePattern,
        @exclude_list    = @DbExcludeList;
END;
GO
