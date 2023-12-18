IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.PlanGuide_SetHintForProcedureStatement'))
    EXEC ('CREATE PROCEDURE dbo.PlanGuide_SetHintForProcedureStatement AS SELECT ''This is a stub''')
GO

ALTER PROCEDURE dbo.PlanGuide_SetHintForProcedureStatement
    @DbName              sysname,
    @ProcedureSchema     sysname,
    @ProcedureName       sysname,
    @StatementMatchText  nvarchar(max),
    @PlanGuideName       sysname,
    @HintText            nvarchar(1000),
    @DropExisting        bit = 0,
    @Debug               bit = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20231216
    This procedure creates (or replaces) a plan guide for a statement within a stored procedure.
    Plan guides require an **EXACT** (binary) match on query text in order for it to work.
    This can sometimes be tricky to get correct, particularly with non-printing characters such
    as varying line endings (CRLF vs LF). This procedure resolves that by allowing you to use a
    wildcarded string to identify the statement text programatically, then constructing the plan
    guide via dynamic SQL to ensure an exact match to the statement.

     To achieve a perfect match, this procedure pulls the directly from sys.dm_exec_query_stats,
     which requires that the stored procedure be executed at least once to generate the query
     stats data to pull from. If the procedure has not been executed, this procedure will fail
     to identify a matching statement.
     
PARAMETERS
* @DbName - Name of the database to create the Plan Guide in
* @ProcedureSchema - Together with @ProcedureName identifies the procedure that contains the statement
                     for which the plan guide will be created.
* @ProcedureName - Together with @ProcedureSchema identifies the procedure that contains the statement
                     for which the plan guide will be created.
* StatementMatchText - Wildcarded portion of the statement that will uniquely identify the statement
                     within the procedure text. By default does a "Begins with%" search.
* PlanGuideName - Name of the plan guide to create (or modify). When modifying a plan guide,
                  you must also set @DropExisting = 1.
* HintText - The text of the hint you want to use in the plan guide.
* DropExisting - Default 0 (false) - When modifying an existing plan guide, you must also set @DropExisting = 1.
* Debug - Default 0 (false) - Instead of creating a plan guide, outputs information, including 
                  dynamic SQL statements that are/would be run.

**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/


SET NOCOUNT ON;
BEGIN

--
    DECLARE @StatementFullText  nvarchar(max);
    DECLARE @ProcedureFQN       nvarchar(1000);
    DECLARE @Sql                nvarchar(max);
    DECLARE @ExistingGuide      bit;
    
    --TODO check if a plan guide with this name already exists;

    SET @StatementMatchText += N'%';
    SET @ProcedureFQN = QUOTENAME(@DbName) + '.' + QUOTENAME(@ProcedureSchema) + '.' + QUOTENAME(@ProcedureName);

    DROP TABLE IF EXISTS #QueryDetails;
    CREATE TABLE #QueryDetails(
        Id                      int identity(1,1) PRIMARY KEY CLUSTERED,
        DbName                  sysname,
        StatementText           nvarchar(max),
        SqlHandle               varbinary(64),
        StatementStartOffset    int,
        StatementEndOffset      int,
        PlanHandle              varbinary(64)
    );

    WITH QueryDetails AS (
        SELECT  DbName = t.DbName,
                StatementText = t.StatementText,
                qs.*
        FROM sys.dm_exec_procedure_stats ps
        JOIN sys.dm_exec_query_stats qs ON ps.sql_handle = qs.sql_handle
        CROSS APPLY dbo.ParseStatementByOffset(ps.sql_handle, qs.statement_start_offset, qs.statement_end_offset) t
        WHERE ps.object_id = object_id(@ProcedureFQN)
        AND ps.database_id = db_id(@DbName)
        )
    INSERT INTO #QueryDetails(DbName, StatementText, SqlHandle, StatementStartOffset, StatementEndOffset, PlanHandle)
    SELECT DbName, StatementText, sql_handle, statement_start_offset, statement_end_offset, plan_handle
    FROM QueryDetails
    WHERE StatementText LIKE @StatementMatchText;

    --TODO need to handle cases where there are != 1 rows returned.
    IF (SELECT COUNT(DISTINCT StatementText) FROM #QueryDetails) > 1
    BEGIN
        SELECT * FROM #QueryDetails;
        THROW 60000, 'There are multiple statements that match this @StatementMatchText. Please be more specific. @StatementMatchText must return exactly 1 row.',1;
    END;

    IF (SELECT COUNT(DISTINCT StatementText) FROM #QueryDetails) = 0
    BEGIN
        SELECT * FROM #QueryDetails;
        THROW 60001, 'There are zero statements that match this criteria. Criteria must return exactly 1 row from the plan cache.',1;
    END;


    IF (@Debug = 1)
    BEGIN
        SELECT * FROM #QueryDetails;
    END;

    SELECT TOP 1
        @StatementFullText = StatementText
    FROM #QueryDetails;

    IF (@Debug = 1)
    BEGIN
        SELECT FullStatementText = @StatementFullText;
    END;

    --Check for existing guides & drop/continue/error based on existence & @DropExisting
    SET @sql = 'SELECT @ExistingGuide = COUNT(*) FROM ' + QUOTENAME(@DbName) + '.sys.plan_guides WHERE name = @PlanGuideName;'
    EXEC sys.sp_executesql @stmt = @sql, 
                        @params = N'@PlanGuideName sysname, @ExistingGuide int OUT', 
                        @PlanGuideName = @PlanGuideName,
                        @ExistingGuide = @ExistingGuide OUT;

    IF (@ExistingGuide = 1 AND @DropExisting = 0)
    BEGIN
        SET @sql = 'SELECT * FROM ' + QUOTENAME(@DbName) + '.sys.plan_guides WHERE name = @PlanGuideName;';
        EXEC sys.sp_executesql @stmt = @sql, 
                    @params = N'@PlanGuideName sysname', 
                    @PlanGuideName = @PlanGuideName;
        THROW 60002, 'An existing Plan Guide already exists with this name. Choose a new name or use @DropExisting=1.', 1;
    END;

    IF (@ExistingGuide = 1 AND @DropExisting = 1)
    BEGIN
        SET @sql = 'EXEC ' + QUOTENAME(@DbName) + '.sys.sp_control_plan_guide N''DROP'', @PlanGuideName;';
        
        IF (@Debug = 0)
        BEGIN
            EXEC sys.sp_executesql @stmt = @sql, 
                        @params = N'@PlanGuideName sysname', 
                        @PlanGuideName = @PlanGuideName;
        END;
        IF (@Debug = 1)
        BEGIN
            PRINT @sql;
            PRINT '@PlanGuideName = ' + @PlanGuideName;
        END;
    END;

    --OK, now finally create the plan guide!
    SET @sql = 'EXEC ' + QUOTENAME(@DbName) + '.sys.sp_create_plan_guide   
            @name =  @PlanGuideName,  
            @stmt = @StatementFullText,  
            @type = N''OBJECT'',  
            @module_or_batch = @ProcedureName,  
            @params = NULL,  
            @hints = @HintText;'

    IF (@Debug = 1)
    BEGIN
        PRINT @sql;
    END;
    IF (@Debug = 0)
    BEGIN
        EXEC sys.sp_executesql
                    @stmt                = @sql,
                    @params              = N'@PlanGuideName sysname, @StatementFullText nvarchar(max), @ProcedureName sysname, @HintText nvarchar(1000)',
                    @PlanGuideName       = @PlanGuideName,
                    @StatementFullText   = @StatementFullText,
                    @ProcedureName       = @ProcedureName,
                    @HintText            = @HintText;
    END;
END;

GO
