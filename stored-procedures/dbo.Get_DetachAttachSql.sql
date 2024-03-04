IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Get_DetachAttachSql'))
    EXEC ('CREATE PROCEDURE dbo.Get_DetachAttachSql AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Get_DetachAttachSql
    @name_pattern         nvarchar(300)  = N'%', 
    @database_list        nvarchar(max)  = NULL,
    @exclude_pattern      nvarchar(300)  = NULL,
    @exclude_list         nvarchar(max)  = 'master,tempdb,model,msdb,distribution,dba',
    @recovery_model_desc  nvarchar(120)  = NULL,
    @compatibility_level  tinyint        = NULL,
    @state_desc           nvarchar(120)  = N'ONLINE',
    @is_read_only         bit = 0
  
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20240304
    This procedure returns a table with the detach & attach SQL code for each database.
    Designed to be used for server migrations or other work where you may need to 
    detach and/or attach every database on an instance. 

    All parameters are inherited from `sp_ineachdb`, and used to control which database(s)
    are included in the output.

    Please don't abuse detach & attach.
    
PARAMETERS
* None
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDDD - Initials - Description of changes
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;
DROP TABLE IF EXISTS #AttachSql;
CREATE TABLE #AttachSql (
    DatabaseId int,
    DbName     sysname,
    AttachSql  nvarchar(max)
    );

DECLARE @ineachdb_sql nvarchar(max);

SET @ineachdb_sql = N'DECLARE @sql nvarchar(max) = N''CREATE DATABASE '' + QUOTENAME(DB_NAME()) + N''
                        ON '';

                        SELECT @sql += N'' (FILENAME = '' + QUOTENAME(physical_name,CHAR(39)) + N''),'' + CHAR(13) + CHAR(10)
                        FROM sys.database_files;

                        SET @sql = LEFT(@sql,LEN(@sql)-1)

                        SET @sql += N'' FOR ATTACH;''

                        SELECT db_id(), db_name(), @sql';

INSERT INTO #AttachSql (DatabaseId, DbName, AttachSql)
EXEC dba.dbo.sp_ineachdb 
    @command              =  @ineachdb_sql,
    @name_pattern         = @name_pattern,
    @database_list        = @database_list,
    @exclude_pattern      = @exclude_pattern,
    @exclude_list         = @exclude_list,
    @recovery_model_desc  = @recovery_model_desc,
    @compatibility_level  = @compatibility_level,
    @state_desc           = @state_desc,
    @is_read_only         = @is_read_only;


WITH DetachSql AS (
        SELECT 
            DatabaseId  = database_id, 
            DbName      = name, 
            DetachSQL   = N'EXEC sp_detach_db @dbname = ' + QUOTENAME(name) + ', @skipchecks = ''true'';'
        FROM sys.databases
        where name NOT IN ('master','tempdb','model','msdb','distribution','dba')
        )
SELECT a.DatabaseId, a.DbName, d.DetachSQL, a.AttachSql
FROM #AttachSql AS a
JOIN DetachSql  AS d ON d.DatabaseId = a.DatabaseId
ORDER BY a.DbName;


GO

