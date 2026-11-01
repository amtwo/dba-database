CREATE OR ALTER PROCEDURE dbo.Check_QueryStore_TopCpuDelta
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
    Runs dbo.QueryStore_TopCpuDelta for each database selected by DBA.dbo.sp_ineachdb.

PARAMETERS
    See dbo.QueryStore_TopCpuDelta for parameter descriptions.

**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
**************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    DECLARE @Command nvarchar(max) = N'EXEC DBA.dbo.QueryStore_TopCpuDelta'
        + N' @DatabaseName = DB_NAME()'
        + N', @WindowStart        = ' + COALESCE(QUOTENAME(CONVERT(nvarchar(35), @WindowStart, 127), ''''), N'NULL')
        + N', @WindowEnd          = ' + COALESCE(QUOTENAME(CONVERT(nvarchar(35), @WindowEnd, 127), ''''), N'NULL')
        + N', @CompareOffsetHours = ' + CONVERT(nvarchar(12), @CompareOffsetHours)
        + N', @Top                = ' + CONVERT(nvarchar(12), @Top)
        + N', @Debug              = ' + CONVERT(nvarchar(1), @Debug) + N';';

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

/* Synonym for backwards compatibility with the legacy procedure name. */
IF OBJECT_ID(N'dbo.Check_QueryStoreRegressedQueries', N'P') IS NOT NULL
    DROP PROCEDURE dbo.Check_QueryStoreRegressedQueries;

IF EXISTS (
    SELECT 1
    FROM sys.synonyms
    WHERE name = N'Check_QueryStoreRegressedQueries'
      AND OBJECT_SCHEMA_NAME(object_id) = N'dbo'
      AND base_object_name <> N'dbo.Check_QueryStore_TopCpuDelta'
)
    DROP SYNONYM dbo.Check_QueryStoreRegressedQueries;

IF NOT EXISTS (
    SELECT 1
    FROM sys.synonyms
    WHERE name = N'Check_QueryStoreRegressedQueries'
      AND OBJECT_SCHEMA_NAME(object_id) = N'dbo'
      AND base_object_name = N'dbo.Check_QueryStore_TopCpuDelta'
)
    EXEC(N'CREATE SYNONYM dbo.Check_QueryStoreRegressedQueries FOR dbo.Check_QueryStore_TopCpuDelta;');
GO
