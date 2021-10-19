IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Cleanup_Msdb'))
    EXEC ('CREATE PROCEDURE dbo.Cleanup_Msdb AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.FindStringInModules
   @search_string               nvarchar(4000),
   @case_sensitive              bit = 0,
   @database_list               nvarchar(max) = NULL,
   @search_jobs                 bit = 0,
   @search_job_and_step_names   bit = 0,
   @search_object_names         bit = 0,
   @search_schema_names         bit = 0,
   @search_column_names         bit = 0,
   @search_parameter_names      bit = 0,
   @search_system_objects       bit = 0,
   @search_system_databases     bit = 0,
   @search_everything           bit = 0,    
   @debug                       bit = 0
AS
/*************************************************************************************************
AUTHOR: <name>
CREATED: YYYYMMDD
    WTF does this do? TLDR

PARAMETERS
* add any necessary parameter documentation here. Assume your param names are confusing to others
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2021 ● Andy Mallon ● am2.co
*************************************************************************************************/
BEGIN
  SET NOCOUNT ON;

  IF @search_everything = 1
  BEGIN
    SELECT
      @search_jobs               = 1,
      @search_job_and_step_names = 1,
      @search_object_names       = 1,
      @search_schema_names       = 1,
      @search_column_names       = 1,
      @search_parameter_names    = 1,
      @search_system_objects     = 1,
      @search_system_databases   = 1;
  END

  DECLARE @sql        nvarchar(max),
          @template   nvarchar(max),
          @exec       nvarchar(1024),
          @all_text   nvarchar(128),
          @coll_text  nvarchar(128);

  SELECT @sql       = N'',
         @template  = N'',
         @all_text  = CASE @search_system_objects 
                      WHEN 1 THEN N'all_' ELSE N'' END,
         @coll_text = CASE @case_sensitive
                      WHEN 1 THEN N'Latin1_General_100_CS_AS_SC'
                      WHEN 0 THEN N'Latin1_General_100_CI_AS_SC' 
                      END;

  CREATE TABLE #o
  (
    [database]   nvarchar(130), 
    [schema]     nvarchar(130), 
    [object]     nvarchar(130), 
    [type]       nvarchar(130), 
    create_date  datetime, 
    modify_date  datetime, 
    column_name  nvarchar(130), 
    param_name   nvarchar(130), 
    definition   xml
  );

  SET @search_string = N'%' + @search_string + N'%';

  SET @template = N'
SELECT [database]     = DB_NAME(),
       [schema]       = s.name,
       [object]       = o.name, 
       [type]         = o.type_desc, 
       o.create_date, 
       o.modify_date,
       [column_name]  = $col$,
       [param_name]   = $param$,
       definition     = CONVERT(xml, ''<?query --''
           + CHAR(13) + CHAR(10) + ''USE '' + QUOTENAME(DB_NAME()) + '';''
           + CHAR(13) + CHAR(10) + ''GO''
           + CHAR(13) + CHAR(10) + OBJECT_DEFINITION(o.object_id) + '' --?>'')
  FROM sys.$all$objects AS o
  INNER JOIN sys.schemas AS s 
    ON o.[schema_id] = s.[schema_id]';

  SET @sql = @sql + REPLACE(REPLACE(@template, N'$col$', N'NULL'), N'$param$', N'NULL')
      + N'
    ' + N' WHERE OBJECT_DEFINITION(o.[object_id]) COLLATE $coll$ 
    ' + N'                                LIKE @s COLLATE $coll$';

  SET @sql = @sql + CASE @search_schema_names WHEN 1 THEN N'
      OR s.name COLLATE $coll$ 
        LIKE @s COLLATE $coll$' ELSE N'' END;
                 
  SET @sql = @sql + CASE @search_object_names WHEN 1 THEN N'
      OR o.name COLLATE $coll$ 
        LIKE @s COLLATE $coll$' ELSE N'' END;

  SET @sql = @sql + CASE @search_column_names WHEN 1 THEN N';
'     + REPLACE(REPLACE(@template, N'$col$', N'c.name'),N'$param$',N'NULL')
      +  N'
         INNER JOIN sys.$all$columns AS c ON o.[object_id] = c.[object_id]
         AND c.name COLLATE $coll$ 
            LIKE @s COLLATE $coll$;' ELSE N'' END;

  SET @sql = @sql + CASE @search_parameter_names WHEN 1 THEN N';
'     + REPLACE(REPLACE(@template, N'$col$', N'NULL'),N'$param$',N'p.name')
      +  N'
         INNER JOIN sys.$all$parameters AS p ON o.[object_id] = p.[object_id]
         AND p.name COLLATE $coll$ 
            LIKE @s COLLATE $coll$;' ELSE N'' END;

  SET @sql = REPLACE(REPLACE(@sql, N'$coll$', @coll_text), N'$all$', @all_text);

  DECLARE @db sysname, @c cursor;
 
  SET @c = cursor FORWARD_ONLY STATIC READ_ONLY FOR
    SELECT QUOTENAME(name) FROM sys.databases AS d
      LEFT OUTER JOIN dbo.fn_split(@database_list, N',') AS s ON 1 = 1
      WHERE
      (
        LOWER(d.name) = LOWER(LTRIM(RTRIM(s.value)))
        OR NULLIF(RTRIM(@database_list), N'') IS NULL
      )
      AND d.database_id >= CASE @search_system_databases
          WHEN 1 THEN 1 ELSE 5 END
      AND d.database_id < 32767
      AND d.state = 0;

  OPEN @c;
  
  FETCH NEXT FROM @c INTO @db;

  WHILE @@FETCH_STATUS = 0
  BEGIN
    SET @exec = @db + N'.sys.sp_executesql';
    
    IF @debug = 1
    BEGIN
      RAISERROR(N'Running dynamic SQL on %s:', 1, 0, @db);
      PRINT @sql;
    END
    ELSE
    BEGIN
      INSERT #o
      (
        [database], 
        [schema], 
        [object], 
        [type], 
        create_date, 
        modify_date, 
        column_name, 
        param_name, 
        definition
      )
      EXEC @exec @sql, N'@s nvarchar(4000)', @s = @search_string;
    END

    FETCH NEXT FROM @c INTO @db;
  END

  /* jobs */

  IF @search_jobs = 1
  BEGIN
    SET @template = N'SELECT
                job_name = j.name,
                s.step_id,
                s.step_name,
                j.date_created,
                j.date_modified,
                [command_with_use] = CONVERT(xml, N''<?query --''
           + CHAR(13) + CHAR(10) + N''USE '' 
           + QUOTENAME(s.database_name) + N'';''
           + CHAR(13) + CHAR(10) + N''GO''
           + CHAR(13) + CHAR(10) + s.[command] + N'' --?>'')
            FROM msdb.dbo.sysjobs AS j
            INNER JOIN msdb.dbo.sysjobsteps AS s
            ON j.job_id = s.job_id
            WHERE s.command COLLATE $coll$
                    LIKE @s COLLATE $coll$'
    + CASE @search_job_and_step_names WHEN 1 THEN
      N' OR j.name      COLLATE $coll$ 
                LIKE @s COLLATE $coll$
         OR s.step_name COLLATE $coll$ 
                LIKE @s COLLATE $coll$'
      ELSE N'' END
    + N' ORDER BY j.name, s.step_id;';

    SET @sql = REPLACE(@template, N'$coll$', @coll_text);

    IF @debug = 1
    BEGIN
      PRINT N'Running this for jobs:';
      PRINT @sql;
    END
    ELSE
    BEGIN
      SELECT [database], 
             [schema], 
             [object], 
             [type], 
             create_date, 
             modify_date, 
             column_name, 
             param_name, 
             definition
      FROM #o;

      EXEC sys.sp_executesql @sql, N'@s nvarchar(4000)', @s = @search_string;
    END
  END
END
GO