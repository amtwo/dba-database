IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Repl_AddArticle'))
    EXEC ('CREATE PROCEDURE dbo.Repl_AddArticle AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Repl_AddArticle
    @PubDbName nvarchar(256),
    @PublicationName nvarchar(256),
    @ArticleName nvarchar(256),
    @SchemaOption binary(8) NULL,
    @Debug bit = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20140101
    This procedure adds a specific article to a given publication.
    The @SchemaOption parameter is hard-coded and might not be the right mask for everyone.
    
PARAMETERS
* 
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDDD - Initials - Description of changes
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON
---------------------
DECLARE @sql nvarchar(max);
DECLARE @OK bit = 1;

IF @SchemaOption IS NULL
BEGIN
    SELECT @SchemaOption = VarbinaryValue 
    FROM dbo.Config
    WHERE ConfigCode = 'REPLSCMOPT';
END;

--Check to see if article exists in Published database
SET @sql = N'SELECT @OK = 0 
            WHERE NOT EXISTS (SELECT 1 FROM [' + @PubDbName + N'].sys.objects WHERE name = @ArticleName);'
EXEC sp_executesql @sql, N'@ArticleName sysname, @OK bit OUTPUT', @ArticleName = @ArticleName, @OK = @OK OUTPUT;
IF @OK = 0
BEGIN
    RAISERROR ('Article does not exist in specified database',16,1);
    RETURN -1;
END

--Check that the article is not already published 
 --If already published, don't error, just print the info.
SET @sql = N'SELECT @OK = 0 
            WHERE EXISTS (SELECT 1 FROM [' + @PubDbName + N'].sys.objects 
                            WHERE name = @ArticleName AND is_published = 1);'
EXEC sp_executesql 
            @stmt = @sql, 
            @params = N'@ArticleName sysname, @OK bit OUTPUT', 
            @ArticleName = @ArticleName, 
            @OK = @OK OUTPUT;
IF @OK = 0
BEGIN
    RAISERROR ('Article is already published',10,1);
    RETURN 0;
END

--and now call the system sproc to actually add the article to publication
DECLARE @InsertCommand nvarchar(128) = N'CALL sp_MSins_dbo' + @ArticleName;
DECLARE @UpdateCommand nvarchar(128) = N'CALL sp_MSupd_dbo' + @ArticleName;
DECLARE @DeleteCommand nvarchar(128) = N'CALL sp_MSdel_dbo' + @ArticleName;


SET @sql = N'EXEC ' + QUOTENAME(@PubDbName) + N'.sys.sp_addarticle 
            @publication                    = @PublicationName, 
            @article                        = @ArticleName, 
            @source_owner                   = N''dbo'', 
            @source_object                  = @ArticleName, 
            @type                           = N''logbased'', 
            @description                    = null, 
            @creation_script                = null, 
            @pre_creation_cmd               = N''drop'', 
            @schema_option                  = @SchemaOption, 
            @identityrangemanagementoption  = N''manual'', 
            @destination_table              = @ArticleName, 
            @destination_owner              = N''dbo'', 
            @vertical_partition             = N''false'', 
            @ins_cmd                        = @InsertCommand, 
            @upd_cmd                        = @UpdateCommand, 
            @del_cmd                        = @DeleteCommand'

IF @Debug = 0
    EXEC sp_executesql @stmt = @sql,
                @params             = N'@PublicationName nvarchar(128),
                                        @ArticleName     nvarchar(128),
                                        @SchemaOption    binary(8),
                                        @InsertCommand   nvarchar(128),
                                        @UpdateCommand   nvarchar(128),
                                        @DeleteCommand   nvarchar(128)',
                @PublicationName    = @PublicationName,
                @ArticleName        = @ArticleName,
                @SchemaOption       = @SchemaOption,
                @InsertCommand      = @InsertCommand,
                @UpdateCommand      = @UpdateCommand,
                @DeleteCommand      = @DeleteCommand;
ELSE
    PRINT @sql;
    PRINT N'    Publication:   ' + @PublicationName
    PRINT N'    Article:       ' + @ArticleName
    PRINT N'    SchemaOption:  ' + CONVERT(nvarchar(max), @SchemaOption)
    PRINT N'    InsertCommand: ' + @InsertCommand
    PRINT N'    UpdateCommand: ' + @UpdateCommand
    PRINT N'    DeleteCommand: ' + @DeleteCommand
    
GO


