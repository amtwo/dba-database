CREATE OR ALTER PROCEDURE dbo.Check_TableUsage
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
        @params nvarchar(500),
        @sql nvarchar(max);

SELECT @params = N'@SchemaName sysname, @TableName sysname';

SELECT @sql = N'IF @SchemaName IS NOT NULL AND SCHEMA_ID(@SchemaName) IS NULL
BEGIN
    RAISERROR(''The specified schema does not exist or is not visible in the target database.'', 16, 1);
    RETURN;
END;

SELECT TableName = schema_name(o.schema_id) + ''.'' + o.name,
       IndexName = i.name,
       us.user_seeks, 
       us.user_scans, 
       us.user_lookups, 
       us.last_user_seek, 
       us.last_user_scan, 
       us.last_user_lookup, 
       us.last_user_update
FROM sys.objects o
JOIN sys.indexes i ON o.object_id = i.object_id
JOIN sys.dm_db_index_usage_stats us ON us.object_id = o.object_id AND us.index_id = i.index_id
WHERE us.database_id = DB_ID()
AND (@SchemaName IS NULL OR o.schema_id = SCHEMA_ID(@SchemaName))
AND o.name LIKE @TableName
ORDER BY schema_name(o.schema_id) + ''.'' + o.name, i.name;

-- referencing code
SELECT ReferencedTableName = schema_name(o.schema_id) + ''.'' + o.name,
       ReferencingEntity = r.referencing_schema_name + ''.'' + r.referencing_entity_name, 
       r.referencing_id, 
       r.referencing_class_desc, 
       r.is_caller_dependent
FROM sys.objects o
CROSS APPLY sys.dm_sql_referencing_entities (QUOTENAME(SCHEMA_NAME(o.schema_id)) + N''.'' + QUOTENAME(o.name), N''OBJECT'') r
WHERE (@SchemaName IS NULL OR o.schema_id = SCHEMA_ID(@SchemaName))
AND o.name LIKE @TableName
ORDER BY schema_name(o.schema_id) + ''.'' + o.name; ';

EXEC @DatabaseExec @sql, @params, @SchemaName = @SchemaName, @TableName = @TableName;
GO
