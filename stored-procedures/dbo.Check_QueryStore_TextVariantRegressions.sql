CREATE OR ALTER PROCEDURE dbo.Check_QueryStore_TextVariantRegressions
    @DbNamePattern      nvarchar(300)     = NULL,
    @DatabaseList       nvarchar(max)     = NULL,
    @DbExcludePattern   nvarchar(300)     = NULL,
    @DbExcludeList      nvarchar(max)     = NULL,
    @VariantSince       datetimeoffset(7),
    @WindowEnd          datetimeoffset(7) = NULL,
    @BaselineStart      datetimeoffset(7) = NULL,
    @BaselineEnd        datetimeoffset(7) = NULL,
    @MinExecs           bigint            = 20,
    @MinRatio           decimal(9, 2)     = 2.0,
    @MinCpuMs           decimal(9, 2)     = 1.0,
    @NormalizeLineEndings bit             = 1,
    @IgnoreAllWhiteSpace bit              = 1,
    @IgnoreCapitalization bit              = 0,
    @Debug              bit               = 0
AS
/*************************************************************************************************
AUTHOR: Cody 🤖
DESCRIPTION
    Runs dbo.QueryStore_TextVariantRegressions for each database selected by dbo.sp_ineachdb.

PARAMETERS
    See dbo.QueryStore_TextVariantRegressions for parameter descriptions.

**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
**************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    DECLARE @Command nvarchar(max) = N'EXEC ' + QUOTENAME(DB_NAME()) + N'.dbo.QueryStore_TextVariantRegressions'
        + N' @DatabaseName = DB_NAME()'
        + N', @VariantSince  = ' + QUOTENAME(CONVERT(nvarchar(35), @VariantSince, 127), '''')
        + N', @WindowEnd     = ' + COALESCE(QUOTENAME(CONVERT(nvarchar(35), @WindowEnd, 127), ''''), N'NULL')
        + N', @BaselineStart = ' + COALESCE(QUOTENAME(CONVERT(nvarchar(35), @BaselineStart, 127), ''''), N'NULL')
        + N', @BaselineEnd   = ' + COALESCE(QUOTENAME(CONVERT(nvarchar(35), @BaselineEnd, 127), ''''), N'NULL')
        + N', @MinExecs      = ' + CONVERT(nvarchar(20), @MinExecs)
        + N', @MinRatio      = ' + CONVERT(nvarchar(30), @MinRatio)
        + N', @MinCpuMs      = ' + CONVERT(nvarchar(30), @MinCpuMs)
        + N', @NormalizeLineEndings = ' + CONVERT(nvarchar(1), @NormalizeLineEndings)
        + N', @IgnoreAllWhiteSpace = ' + CONVERT(nvarchar(1), @IgnoreAllWhiteSpace)
        + N', @IgnoreCapitalization = ' + CONVERT(nvarchar(1), @IgnoreCapitalization)
        + N', @Debug         = ' + CONVERT(nvarchar(1), @Debug) + N';';

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
