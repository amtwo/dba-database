USE master
GO
--We don't want to drop/create this guy once we mark it as system
--Once a developer starts using this in production, will cause problems when it disappears
--Instead: if it doesn't exist, create a stub & grant permissions, then alter the sproc to use the correct code.
IF OBJECT_ID('sp_get_basetable_list', 'P') IS  NULL
BEGIN
	--do this in dynamic SQL so CREATE PROCEDURE can be nested in this IF block
	EXEC ('CREATE PROCEDURE dbo.sp_get_basetable_list AS SELECT 1')
	--mark it as a system object
	EXEC sp_MS_marksystemobject sp_get_basetable_list
	--grant permission to the whole world
	GRANT EXECUTE ON sp_get_basetable_list to PUBLIC
END
GO

--Now do an alter
ALTER PROCEDURE dbo.sp_get_basetable_list
@object_name varchar(776) = NULL,
@debug bit = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20140228
       This procedure can be called two ways:
	   1) by passing a view/synonym/table name to the @object_name parameter
	   2) by creating & populating #tables (matching schema at start of sproc) then calling the 
	      sproc with that table populated.

	   If option 1 is used to call the sproc, the table list will be returned in the form
	   of a result set.
	   If option 2 is used to call the sproc, then #tables will be populated with the physical 
	   tables.
	   
	   For the object(s) passed to this sproc, look up the physical tables behind it.
	   * If a synonym is passed, return the base table of that synonym
	   * If a view is passed, return ALL the base tables of that view
	   * If a table is passed, return the table itself

	   Lookup is recursive and only ends when #tables contains only tables.

PARAMETERS
* @object_name - Optional - accept three-part object name (Database.Schema.Table)
		- If not provided, #tables should exist & be populated, otherwise, raiserror
**************************************************************************************************
MODIFICATIONS:
       YYYYMMDDD - Initials - Description of changes
*************************************************************************************************/

SET NOCOUNT ON
	--If #tables doesn't exist, create it, and populate it from the input param
	
	IF (object_id('tempdb..#tables') IS NULL)
	BEGIN
		IF @object_name IS NULL
			RAISERROR ('No table(s) provided.',16,1)
		CREATE TABLE #tables (DbName sysname, SchemaName sysname, TableName sysname, ObjType char(2) CONSTRAINT pk_tables PRIMARY KEY (DbName, SchemaName, TableName))
		INSERT INTO #tables (DbName, SchemaName, TableName)
		SELECT COALESCE(parsename(@object_name,3),db_name()),
			COALESCE(parsename(@object_name,2),schema_name()),
			parsename(@object_name,1)
	END


	DECLARE @sql nvarchar(2070)
	DECLARE @DbName varchar(256)
	DECLARE @SchemaName varchar(256)
	DECLARE @TableName varchar(256)
	DECLARE @ObjType char(2)
	
	WHILE EXISTS(SELECT 1 FROM #tables WHERE COALESCE(ObjType,'x') <> 'U')
	BEGIN
		DECLARE db_cur CURSOR FOR
			SELECT DISTINCT DbName FROM #tables

		OPEN db_cur
		FETCH NEXT FROM db_cur INTO @DbName

		WHILE @@FETCH_STATUS = 0
		BEGIN
			-- Get the object types for everything in this DB
			SET @sql = N'UPDATE t SET ObjType = o.type FROM #tables t JOIN ' + @DbName + '.sys.objects o ON o.schema_id = schema_id(t.SchemaName) AND o.name = t.TableName WHERE t.DbName = ''' + @DbName + ''''
			IF @debug = 1
				PRINT @sql
			EXEC (@sql)

			IF EXISTS (SELECT 1 FROM #tables WHERE DbName = @DbName AND ObjType IS NULL)
			BEGIN
				PRINT 'Unable to determine object type for one or more objects.'
				DELETE FROM #tables WHERE DbName = @DbName AND ObjType IS NULL
			END

			DECLARE tab_cur CURSOR FOR
				SELECT SchemaName, TableName, ObjType
				FROM #tables
				WHERE DbName = @DbName

			OPEN tab_cur
			FETCH NEXT FROM tab_cur INTO @SchemaName, @TableName, @ObjType
			WHILE @@FETCH_STATUS = 0
			BEGIN
				IF (@ObjType ='SN') 
				BEGIN
					--Its not a table. Delete the current row & replace with object(s) it references
					DELETE #tables WHERE DbName = @DbName AND SchemaName = @SchemaName AND TableName = @TableName
					SET @sql = N'INSERT INTO #tables (DbName, SchemaName, TableName) SELECT COALESCE(PARSENAME(base_object_name,3),db_name()), '
							+ 'COALESCE(PARSENAME(base_object_name,2),schema_name()), PARSENAME(base_object_name,1)  FROM ' + @DbName 
								+ '.sys.synonyms WHERE name = ''' + @TableName + ''' AND schema_id = schema_id(''' + @SchemaName + ''')'
					IF @debug = 1
						PRINT @sql
					EXEC (@sql)
				END 
				
				ELSE IF (@ObjType <> 'U')
				BEGIN
					--Its not a table. Delete the current row & replace with object(s) it references
					DELETE #tables WHERE DbName = @DbName AND SchemaName = @SchemaName AND TableName = @TableName
					SET @sql = N'INSERT INTO #tables (DbName, SchemaName, TableName) SELECT DISTINCT COALESCE(referenced_database_name,''' 
							+ @DbName + '''), COALESCE(referenced_schema_name,''' + @SchemaName + '''), referenced_entity_name FROM ' + QUOTENAME(@DbName) 
							+ '.sys.dm_sql_referenced_entities (''' + QUOTENAME(@SchemaName) + '.' + QUOTENAME(@TableName) + ''',''OBJECT'') r '
							+ 'WHERE NOT EXISTS(SELECT 1 FROM #tables t WHERE t.DbName = COALESCE(r.referenced_database_name,''' + @DbName + ''') AND '
							+ 't.SchemaName = COALESCE(r.referenced_schema_name,''' + @SchemaName + ''') AND t.TableName = r.referenced_entity_name)'
					IF @debug = 1
						PRINT @sql
					EXEC (@sql)
				END
				FETCH NEXT FROM tab_cur INTO @SchemaName, @TableName, @ObjType
			END

			CLOSE tab_cur
			DEALLOCATE tab_cur
			FETCH NEXT FROM db_cur INTO @DbName
		END
		CLOSE db_cur
		DEALLOCATE db_cur
	END

	IF (@object_name IS NOT NULL)
		SELECT DbName, SchemaName, TableName FROM #tables

	GO


