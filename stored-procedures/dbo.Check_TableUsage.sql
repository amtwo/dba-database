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
    This code is licensed under the GNU GPL, as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2019 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

DECLARE @params nvarchar(500),
        @sql nvarchar(max);

SELECT @params = N'@DbName sysname, @SchemaName sysname, @TableName sysname';

SELECT @sql = N'SELECT TableName = schema_name(o.schema_id) + ''.'' + o.name,
       IndexName = i.name,
       us.user_seeks, 
       us.user_scans, 
       us.user_lookups, 
       us.last_user_seek, 
       us.last_user_scan, 
       us.last_user_lookup, 
       us.last_user_update
FROM ' + QUOTENAME(@DbName) + N'.sys.objects o
JOIN ' + QUOTENAME(@DbName) + N'.sys.indexes i ON o.object_id = i.object_id
JOIN sys.dm_db_index_usage_stats us ON us.object_id = o.object_id AND us.index_id = i.index_id
WHERE us.database_id = db_id(@DbName)
AND o.schema_id = COALESCE(schema_id(@SchemaName),o.schema_id)
AND o.name LIKE @TableName
ORDER BY schema_name(o.schema_id) + ''.'' + o.name, i.name; ';

EXEC sp_executesql @statement = @sql, @params = @params, @DbName = @DbName, @SchemaName = @SchemaName, @TableName = @TableName;


--referencing code
SELECT @sql = N'SELECT ReferencedTableName = schema_name(o.schema_id) + ''.'' + o.name,
       ReferencingEntity = r.referencing_schema_name + ''.'' + r.referencing_entity_name, 
       r.referencing_id, 
       r.referencing_class_desc, 
       r.is_caller_dependent
FROM ' + QUOTENAME(@DbName) + N'.sys.objects o
CROSS APPLY ' + QUOTENAME(@DbName) + N'.sys.dm_sql_referencing_entities (schema_name(o.schema_id) + ''.'' + o.name, ''OBJECT'') r
WHERE o.schema_id = COALESCE(schema_id(@SchemaName),o.schema_id)
AND o.name LIKE @TableName
ORDER BY schema_name(o.schema_id) + ''.'' + o.name; ';

EXEC sp_executesql @statement = @sql, @params = @params, @DbName = @DbName, @SchemaName = @SchemaName, @TableName = @TableName;


GO
