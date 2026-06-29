CREATE OR ALTER PROCEDURE dbo.Set_StatisticsNorecomputeByTable
    @ObjectList           dbo.ObjectNameListWithDb READONLY,
    @SampleSize           tinyint            = 100,
    @IncludeIndexStats    bit                = 1,
    @IncludeColumnStats   bit                = 0,
    @Debug                bit                = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20240820
       This procedure can be used to enable or disable the "norecompute" flag on statistics for
       specific tables. If the stats object is already flagged as "norecompute" that stats object
       will not be touched.
       
       This can be helpful for very large, high volume tables with volatile stats, where you want
       only manually-trigger stats updates, and do not want auto stats triggered 
       due to small sample size used on large tables.

       This will perform an UPDATE STATISTICS operation when run.

PARAMETERS
* @ObjectList           - Required - TVP of objects that should have stats modified.
* @IncludeIndexStats    - Defaults to 1 (true). 
* @IncludeColumnStats   - Defaults to 1 (true). 
* @SampleSize           - Defaults to 100 (FULLSCAN).
* @Debug                - Defaults to False. Supplying a 1 for this bit will not perform any 
                          changes to stats, but will instead simply output the
                          constructed SQL.

EXAMPLES:

                          
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2024 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

CREATE TABLE #Results (
    DbName sysname,
    SchemaName sysname,
    ObjectName sysname,
    StatisticsList nvarchar(max),
    UpdateStatsSql AS N'UPDATE STATISTICS ' + QUOTENAME(DbName) + N'.' + QUOTENAME(SchemaName) + N'.' + QUOTENAME(ObjectName) + N'
                        (' + StatisticsList + N'
                        ) WITH SAMPLE @@@SampleSize PERCENT, NORECOMPUTE;'
    );

DECLARE @DbName sysname;
DECLARE @sql nvarchar(max)


DECLARE db_cursor CURSOR FOR 
    SELECT DISTINCT DbName FROM @ObjectList ;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0  
BEGIN  
      --Are we doing Index stats?
      IF @IncludeIndexStats = 1
      BEGIN
          SET @sql = N'
                SELECT @DbName, s.name, o.name, STRING_AGG(CONVERT(nvarchar(max),st.name),N'','')
                FROM ' + QUOTENAME(@DbName) + N'.sys.objects o
                JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON s.schema_id = o.schema_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.indexes i ON i.object_id = o.object_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.stats st  ON st.object_id = o.object_id AND st.name = i.name 
                JOIN @ObjectList ol ON 
                            ol.DbName = @DbName
                            AND ol.SchemaName = s.name 
                            AND ol.ObjectName = o.name
                WHERE st.no_recompute = 0 /*Only stats that arent already norecompute*/
                GROUP BY s.name, o.name';
      
        IF @Debug = 1
        BEGIN
            EXEC dbo.Debug_Print @DebugMessage = @sql;
        END;

        INSERT INTO #Results (DbName, SchemaName, ObjectName, StatisticsList)
        EXEC sys.sp_executesql 
                @stmt = @sql, 
                @params = N'@DbName sysname, @ObjectList dbo.ObjectNameListWithDb READONLY',
                @DbName = @DbName,
                @ObjectList = @ObjectList;
    END;

    --Are we doing Column stats?
      IF @IncludeColumnStats = 1
      BEGIN
          SET @sql = N'
                SELECT @DbName, s.name, o.name, STRING_AGG(CONVERT(nvarchar(max),st.name),N'','')
                FROM ' + QUOTENAME(@DbName) + N'.sys.objects o
                JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON s.schema_id = o.schema_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.stats st  ON st.object_id = o.object_id 
                JOIN @ObjectList ol ON 
                            ol.DbName = @DbName
                            AND ol.SchemaName = s.name 
                            AND ol.ObjectName = o.name
                WHERE NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.indexes i WHERE i.object_id = o.object_id AND st.name = i.name )
                AND st.no_recompute = 0 /*Only stats that arent already norecompute*/
                GROUP BY s.name, o.name';
      
        IF @Debug = 1
        BEGIN
            EXEC dbo.Debug_Print @DebugMessage = @sql;
        END;

        INSERT INTO #Results (DbName, SchemaName, ObjectName, StatisticsList)
        EXEC sys.sp_executesql 
                @stmt = @sql, 
                @params = N'@DbName sysname, @ObjectList dbo.ObjectNameListWithDb READONLY',
                @DbName = @DbName,
                @ObjectList = @ObjectList;
    END;

    FETCH NEXT FROM db_cursor INTO @DbName;
END 

CLOSE db_cursor;
DEALLOCATE db_cursor;

IF @Debug = 1
BEGIN
    SELECT * FROM #Results;
END;

SET @sql = N''
SELECT @sql += REPLACE(UpdateStatsSql,N'@@@SampleSize', CONVERT(nvarchar(max),@SampleSize)) + CHAR(13) + CHAR(10)
FROM #Results;

IF @Debug = 1
BEGIN
    EXEC dbo.Debug_Print @DebugMessage = @sql;
END;

IF @Debug = 0
BEGIN
    EXEC sys.sp_executesql @stmt = @sql;
END;
GO
