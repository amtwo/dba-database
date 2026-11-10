IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Views_RecompileAll'))
    EXEC ('CREATE PROCEDURE dbo.Views_RecompileAll AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Views_RecompileAll
    @DbName nvarchar(128),
    @Debug  bit = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20150511
       This procedure loops through all views in a database and marks them for recompilation.
       If NULL is passed for DbName, all views in all databases will be marked for recompilation.

       If a linked server is moved or column data type changed, views referencing that server/column
       may need to be recompiled to realize the issue. This sproc is a quick fix to hit all views 
       in order to resolve the problem.

PARAMETERS
* @DbName - Required - The name of a database to recompile views for. If NULL, do all Databases.
* @Debug - default 0 - determines if sp_recompile statements should be output or executed
EXAMPLES:
* 
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDD - 
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

DECLARE @Sql           nvarchar(max),
        @DatabaseExec  nvarchar(300),
        @RecompileProc nvarchar(300),
        @ViewName      nvarchar(517);


CREATE TABLE #Commands (
    DbName sysname,
    ViewName nvarchar(517)
    )

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name AS DbName
    FROM sys.databases AS d
    WHERE d.state_desc = N'ONLINE'
      AND HAS_DBACCESS(d.name) = 1
      AND (d.replica_id IS NULL OR
           CASE
               -- The helper accepts AG names too and compares names case-insensitively.
               WHEN EXISTS (
                   SELECT 1
                   FROM sys.availability_groups AS ag
                   WHERE ag.name COLLATE SQL_Latin1_General_CP1_CI_AS = d.name COLLATE SQL_Latin1_General_CP1_CI_AS
               ) OR EXISTS (
                   SELECT 1
                   FROM sys.databases AS otherDb
                   WHERE otherDb.database_id <> d.database_id
                     AND otherDb.name COLLATE SQL_Latin1_General_CP1_CI_AS = d.name COLLATE SQL_Latin1_General_CP1_CI_AS
               )
                   THEN sys.fn_hadr_is_primary_replica(d.name)
               WHEN dbo.AGDbRole_Get(d.name) = N'PRIMARY' THEN 1
               ELSE 0
           END = 1)
      AND (@DbName IS NULL OR d.name = @DbName);

DECLARE cmd_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DbName, ViewName FROM #Commands;


--Build commands one Db at a time, store in #Commands table
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @DatabaseExec = QUOTENAME(@DbName) + N'.sys.sp_executesql';
    SET @Sql = N'SELECT DB_NAME(), QUOTENAME(s.name) + N''.'' + QUOTENAME(v.name)
        FROM sys.views AS v
        JOIN sys.schemas AS s ON s.schema_id = v.schema_id
        WHERE v.is_ms_shipped = 0;';

    INSERT INTO #Commands (DbName, ViewName)
    EXEC @DatabaseExec @Sql;

    FETCH NEXT FROM db_cur INTO @DbName;
END;

CLOSE db_cur;
DEALLOCATE db_cur;


IF @Debug = 1
BEGIN
    --If Debug mode, just select out the commands.
    SELECT Cmd = N'EXEC ' + QUOTENAME(DbName) + N'.sys.sp_recompile @objname = N'''
               + REPLACE(ViewName, N'''', N'''''') + N''';'
    FROM #Commands;
END;
ELSE
BEGIN
    --Otherwise, execute them
    OPEN cmd_cur;
    FETCH NEXT FROM cmd_cur INTO @DbName, @ViewName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
    
        SET @RecompileProc = QUOTENAME(@DbName) + N'.sys.sp_recompile';
        EXEC @RecompileProc @objname = @ViewName;
        
        FETCH NEXT FROM cmd_cur INTO @DbName, @ViewName;
    END;

    CLOSE cmd_cur;
    DEALLOCATE cmd_cur;
END;

RETURN 0;
GO


