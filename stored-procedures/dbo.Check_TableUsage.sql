IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Check_TableUsage'))
    EXEC ('CREATE PROCEDURE dbo.Check_TableUsage AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Check_TableUsage
    @DbName sysname,
    @SchemaName sysname,
    @TableName sysname
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20170916
    This checks index usage stats plus dependency references *from within the same db* to 
    as one tool to help determine if a table is being actively used.
       
PARAMETERS
* @DbName       - Name of the database to evaluate
* @SchemaName   - Name of the schema to evaluate. If NULL, checks all schemas.
* @TableName    - Name of the table to evaluate. Can be wildcarded.
EXAMPLES:

**************************************************************************************************
MODIFICATIONS:
    20150107 - 
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

IF DB_ID(@DbName) IS NULL
BEGIN
    RAISERROR('The specified database does not exist or is not visible.', 16, 1);
    RETURN;
END;

DECLARE @DatabaseExec nvarchar(300) = QUOTENAME(@DbName) + N'.sys.sp_executesql',
        @Sql          nvarchar(max);

SET @Sql = N'
IF @SchemaName IS NOT NULL AND SCHEMA_ID(@SchemaName) IS NULL
BEGIN
    RAISERROR(''The specified schema does not exist or is not visible in the target database.'', 16, 1);
    RETURN;
END;

SELECT TableName = s.name + N''.'' + o.name,
       IndexName = i.name,
       us.user_seeks,
       us.user_scans,
       us.user_lookups,
       us.last_user_seek,
       us.last_user_scan,
       us.last_user_lookup,
       us.last_user_update
FROM sys.tables AS o
JOIN sys.schemas AS s ON s.schema_id = o.schema_id
JOIN sys.indexes AS i ON i.object_id = o.object_id
JOIN sys.dm_db_index_usage_stats AS us ON us.object_id = o.object_id AND us.index_id = i.index_id
WHERE us.database_id = DB_ID()
  AND (@SchemaName IS NULL OR s.name = @SchemaName)
  AND o.name LIKE @TableName
ORDER BY s.name, o.name, i.name;

SELECT ReferencedTableName = s.name + N''.'' + o.name,
       ReferencingEntity = r.referencing_schema_name + N''.'' + r.referencing_entity_name,
       r.referencing_id,
       r.referencing_class_desc,
       r.is_caller_dependent
FROM sys.tables AS o
JOIN sys.schemas AS s ON s.schema_id = o.schema_id
CROSS APPLY sys.dm_sql_referencing_entities(QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name), N''OBJECT'') AS r
WHERE (@SchemaName IS NULL OR s.name = @SchemaName)
  AND o.name LIKE @TableName
ORDER BY s.name, o.name;';

EXEC @DatabaseExec @Sql, N'@SchemaName sysname, @TableName sysname',
    @SchemaName = @SchemaName, @TableName = @TableName;
GO
