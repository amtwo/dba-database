IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Check_ProcPerf'))
    EXEC ('CREATE PROCEDURE dbo.Check_ProcPerf AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Check_ProcPerf
    @ObjectName nvarchar(max) = NULL
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20171201
       This returns some basic data from sys.dm_exec_procedure_stats
PARAMETERS
Must supply either @ObjectName or @ObjectNameWildcard
* @ObjectName - Default NULL - Stored procedure that you want performance info for.
                               Can be a single object name, or a CSV of object names
                               Object Name should be three-part name

EXAMPLES:
* 
**************************************************************************************************
MODIFICATIONS:
       20171201 - Initials - Modification description
       
**************************************************************************************************
    This code is free to download and use for personal, educational, and internal 
    corporate purposes, provided that this header is preserved. Redistribution or sale, 
    in whole or in part, is prohibited without the author's express written consent.
    ©2014-2017 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

SELECT DbName               = PARSENAME(o.value,3),
       SchemaName           = PARSENAME(o.value,2),
       ProcedureName        = PARSENAME(o.value,1),
       CachedTime           = ps.cached_time,
       TimeSinceCached      = CAST(DATEDIFF(minute,ps.cached_time,getdate())/1440 AS varchar(15)) + 'd ' 
                                + CONVERT(varchar(15),DATEADD(minute,DATEDIFF(minute,ps.cached_time,getdate())%1440,'00:00:00'),8),
       ExecutionCount       = ps.execution_count, 
       TotalCpuTime_sec     = ps.total_worker_time/1000000,
       TotalElapsedTime_sec = ps.total_elapsed_time/1000000,
       TotalLogicalReads    = ps.total_logical_reads,
       TotalLogicalReads_mb = ps.total_logical_reads*8/1024/1024,
       AvgCpuTime_ms        = ps.total_worker_time/ps.execution_count/1000,
       AvgElapsedTime_ms    = ps.total_elapsed_time/ps.execution_count/1000,
       AvgLogicalReas       = ps.total_logical_reads/ps.execution_count
FROM dbo.fn_split(@ObjectName,',') o
JOIN sys.dm_exec_procedure_stats ps ON ps.object_id = object_id(o.value) ;

GO