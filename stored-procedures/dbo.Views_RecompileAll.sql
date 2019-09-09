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
    This code is licensed under the GNU GPL, as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2019 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

DECLARE @Sql nvarchar(max);


CREATE TABLE #Commands (
    Cmd nvarchar(max)
    )

DECLARE db_cur CURSOR FOR
    SELECT name AS DbName
    FROM sys.databases 
    WHERE dbo.dm_hadr_db_role(name) IN ('PRIMARY','ONLINE')
    AND name = COALESCE(@DbName,name);

DECLARE cmd_cur CURSOR FOR
    SELECT Cmd
    FROM #Commands;


--Build commands one Db at a time, store in #Commands table
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = 'SELECT ''EXEC ' + @DbName + '.sys.sp_recompile '''''' + name + '''''';'' FROM [' + @DbName + '].sys.objects WHERE type = ''V'' AND is_ms_shipped = 0;';
    
    INSERT INTO #Commands (Cmd)
    EXEC sp_executesql @Sql
    
    FETCH NEXT FROM db_cur INTO @DbName;
END;

CLOSE db_cur;
DEALLOCATE db_cur;


IF @Debug = 1
BEGIN
    --If Debug mode, just select out the commands.
    SELECT Cmd FROM #Commands;
END;
ELSE
BEGIN
    --Otherwise, execute them
    OPEN cmd_cur;
    FETCH NEXT FROM cmd_cur INTO @Sql;

    WHILE @@FETCH_STATUS = 0
    BEGIN
    
        EXEC sp_executesql @Sql
        
        FETCH NEXT FROM cmd_cur INTO @Sql;
    END;

    CLOSE cmd_cur;
    DEALLOCATE cmd_cur;
END;

RETURN 0;
GO


