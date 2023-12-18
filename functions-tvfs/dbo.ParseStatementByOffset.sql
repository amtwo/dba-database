IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'IF' AND object_id = object_id('dbo.ParseStatementByOffset'))
    EXEC ('CREATE FUNCTION dbo.ParseStatementByOffset() RETURNS TABLE AS RETURN SELECT Result = ''This is a stub'';' )
GO


ALTER FUNCTION dbo.ParseStatementByOffset (
    @SqlHandle   	varbinary(64),
    @StartOffset int,
    @EndOffset   int
    )
RETURNS TABLE
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20231216
    Parses a statement out of the query text, based on the offsets used in DMVs (eg dm_exec_query_stats)

    Output contains the DatabaseId, DbName, ObjectId, ObjectName, and statement text.
PARAMETERS:
    @SqlHandle - Sql Handle (or Plan Handle) that is used to parse text.
    @StartOffset - Indicates, in bytes, beginning with 0, the starting position of the query that 
                   the row describes within the text of its batch or persisted object.
    @EndOffset - 	Indicates, in bytes, starting with 0, the ending position of the query that the 
                   row describes within the text of its batch or persisted object.
EXAMPLES:
          SELECT st.*
          FROM sys.dm_exec_query_stats AS qs
          CROSS APPLY dba.dbo.ParseStatementByOffset (qs.sql_handle, 
                                                      qs.statement_start_offset, 
                                                      qs.statement_end_offset
                                                      ) AS st
          WHERE qs.execution_count > 1000000;
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
RETURN
    SELECT DatabaseId = t.dbid,
           DbName     = DB_NAME(t.dbid),
           ObjectId   = t.objectid,
           ObjectName = OBJECT_NAME(t.objectid, t.dbid),
           StatementText = COALESCE(
                  SUBSTRING(t.text, (@StartOffset/2)+1, (
                                    (CASE @EndOffset
                                        WHEN -1 THEN DATALENGTH(t.text)
                                        ELSE @EndOffset
                                        END - @StartOffset)
                   /2) + 1),'')
    FROM sys.dm_exec_sql_text (@SqlHandle) AS t;

GO

