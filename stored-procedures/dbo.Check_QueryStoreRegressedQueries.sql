CREATE OR ALTER  PROCEDURE dbo.Check_QueryStoreRegressedQueries 
    --These get passed to sp_ineachdb to control which DBs we run for:
    @DbNamePattern      nvarchar(300)       = NULL, 
    @DatabaseList       nvarchar(max)       = NULL,
    @DbExcludePattern   nvarchar(300)       = NULL,
    @DbExcludeList      nvarchar(max)       = NULL,
    --These are the params that control the data returned from Query Stor
    @results_row_count	int					= 25,
    @recent_start_time	datetimeoffset(7)	= NULL,
    @recent_end_time	datetimeoffset(7)	= NULL,
    @history_start_time datetimeoffset(7)	= NULL,
    @history_end_time	datetimeoffset(7)	= NULL,
    @min_exec_count		bigint				= 2,
    -- AM2 special sauce
    @Debug              bit                 = 0
AS
BEGIN
    SET NOCOUNT ON;
        --
    SELECT 
        @recent_start_time	= COALESCE(@recent_start_time	,DATEADD(HOUR,-2,GETDATE())),
        @recent_end_time	= COALESCE(@recent_end_time	,GETDATE()),
        @history_start_time	= COALESCE(@history_start_time	,DATEADD(DAY,-7,GETDATE())),
        @history_end_time	= COALESCE(@history_end_time	,GETDATE());

    IF @Debug = 1
    BEGIN
        SELECT
            ResultsRowCount		= @results_row_count ,
            RecentStartTime		= @recent_start_time ,
            RecentEndTime		= @recent_end_time   ,
            BaselineStartTime	= @history_start_time,
            BaselineEndTime		= @history_end_time	 ,
            MinExecCount		= @min_exec_count	 ;
    END;

    DECLARE @CheckSql nvarchar(max);

    SET @CheckSql = N'
    DECLARE
        @results_row_count	int					,
        @recent_start_time	datetimeoffset(7)	,
        @recent_end_time	datetimeoffset(7)	,
        @history_start_time datetimeoffset(7)	,
        @history_end_time	datetimeoffset(7)	,
        @min_exec_count		bigint				;

    SELECT
        @results_row_count	= ' + CONVERT(nvarchar(10),@results_row_count) + N',
        @recent_start_time	= ' + QUOTENAME(CONVERT(nvarchar(35),@recent_start_time)  , CHAR(39))+ N',
        @recent_end_time	= ' + QUOTENAME(CONVERT(nvarchar(35),@recent_end_time)    , CHAR(39))+ N',
        @history_start_time = ' + QUOTENAME(CONVERT(nvarchar(35),@history_start_time) , CHAR(39))+ N',
        @history_end_time	= ' + QUOTENAME(CONVERT(nvarchar(35),@history_end_time)   , CHAR(39))+ N',
        @min_exec_count		= ' + CONVERT(nvarchar(10),@min_exec_count) + N';

    WITH   hist AS  (
        SELECT
            p.query_id query_id,
            ROUND(CONVERT(float, SUM(rs.avg_duration*rs.count_executions))*0.001,2) total_duration,      
            SUM(rs.count_executions) count_executions,      
            COUNT(distinct p.plan_id) num_plans  
        FROM sys.query_store_runtime_stats rs
        JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id  
        WHERE NOT (rs.first_execution_time > @history_end_time OR rs.last_execution_time < @history_start_time)  
        GROUP BY p.query_id  
        ),  
    recent AS  (  
        SELECT      
            p.query_id query_id,      
            ROUND(CONVERT(float, SUM(rs.avg_duration*rs.count_executions))*0.001,2) total_duration,      
            SUM(rs.count_executions) count_executions,      
            COUNT(distinct p.plan_id) num_plans  
        FROM sys.query_store_runtime_stats rs      
        JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id  
        WHERE NOT (rs.first_execution_time > @recent_end_time OR rs.last_execution_time < @recent_start_time)  
        GROUP BY p.query_id  )  
    SELECT TOP (@results_row_count)      
        results.query_id query_id,      
        results.object_id object_id,      
        ISNULL(OBJECT_NAME(results.object_id),'''') object_name,      
        results.query_sql_text query_sql_text,      
        results.additional_duration_workload additional_duration_workload,      
        results.total_duration_recent total_duration_recent,      
        results.total_duration_hist total_duration_hist,      
        ISNULL(results.count_executions_recent, 0) count_executions_recent,      
        ISNULL(results.count_executions_hist, 0) count_executions_hist,      
        queries.num_plans num_plans  
    FROM  (  
            SELECT      
                hist.query_id query_id,      
                q.object_id object_id,      
                qt.query_sql_text query_sql_text,      
                ROUND(CONVERT(float, recent.total_duration/recent.count_executions-hist.total_duration/hist.count_executions)*(recent.count_executions), 2) additional_duration_workload,      
                ROUND(recent.total_duration, 2) total_duration_recent,      
                ROUND(hist.total_duration, 2) total_duration_hist,      
                recent.count_executions count_executions_recent,      
                hist.count_executions count_executions_hist  
            FROM hist      
            JOIN recent ON hist.query_id = recent.query_id      
            JOIN sys.query_store_query q ON q.query_id = hist.query_id      
            JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id  
            WHERE      recent.count_executions >= @min_exec_count  
            ) AS results  
    JOIN  (  
            SELECT      
                p.query_id query_id,      
                COUNT(distinct p.plan_id) num_plans  
            FROM sys.query_store_plan p  
            GROUP BY p.query_id  
            HAVING COUNT(distinct p.plan_id) >= 1  
            ) AS queries ON queries.query_id = results.query_id  
    WHERE additional_duration_workload > 0  
    ORDER BY additional_duration_workload DESC  
    OPTION (MERGE JOIN);';

    PRINT @CheckSql;

    EXEC DBA.dbo.sp_ineachdb 
        @command              = @CheckSQL,
        @print_command        = @Debug,
        @name_pattern         = @DbNamePattern,
        @database_list        = @DatabaseList,
        @exclude_pattern      = @DbExcludePattern,
        @exclude_list         = @DbExcludeList


END
GO

