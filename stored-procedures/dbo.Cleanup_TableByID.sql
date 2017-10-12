IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Cleanup_TableByID'))
    EXEC ('CREATE PROCEDURE dbo.Cleanup_TableByID AS SELECT ''This is a stub''')
GO


ALTER PROCEDURE dbo.Cleanup_TableByID
    @DbName nvarchar(128),
    @SchemaName nvarchar(128) = 'dbo',
    @TableName nvarchar(128),
    @DateColumnName nvarchar(128),
    @IDColumnName nvarchar(128),
    @RetainDays int = 180,
    @ChunkSize int = 5000,
    @LoopWaitTime time = '00:00:00.5',
    @Debug bit = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20171012
    This procedure cleans up data in the specified database & table.
    This procedure requires that the table have an ID column, AND some sort of date/time column.
    The ID is used for efficiency when doing deletes, and the date/time column is needed to
    determine when data ages out. 
    This includes two controls to help minimize blocking and prevent the transaction log from
    growing during a large data cleanup. These two params can be adjusted to fine-tune the cleanup
       @ChunkSize controls how the max size of each delete operation.
       @LoopWaitTime introduces a wait between each delete to throttle activity between log backups


PARAMETERS
* @DbName         - Name of the database containing the table
* @SchemaName     - Name of the schema containing the table
* @TableName      - Table to be cleaned up
* @DateColumnName - Name of the date/time column to be used to determine cleanup
* @IDColumnName   - Name of the IDENTITY column, to be used for Chunking of deletes
* @RetainDays     - Number of days to retain data before cleaning up
* @ChunkSize      - Number of rows to delete in each batch
* @LoopWaitTime   - Time to wait after each delete. 
* @Debug          - Print DELETE statements instead of actually deleting.
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDD - 
**************************************************************************************************
    This code is free to download and use for personal, educational, and internal 
    corporate purposes, provided that this header is preserved. Redistribution or sale, 
    in whole or in part, is prohibited without the author's express written consent.
    ©2014-2017 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

DECLARE @MaxID bigint;
DECLARE @ChunkID bigint;
DECLARE @Sql nvarchar(max);

--Shuffle this into datetime datatype to make WAITFOR DELAY happy. Still use time on the param for better validation
DECLARE @LoopWaitDateTime datetime = @LoopWaitTime;
--Plop the quoted DB.Schema.Table into one variable so I don't screw it up later.
DECLARE @SqlObjectName nvarchar(386) = QUOTENAME(@DbName) + N'.' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);

--
-- Get the range of ID values we want to delete
--
SELECT @sql = N'SELECT @ChunkID = MIN(' + QUOTENAME(@IDColumnName) + N'), @MaxID = MAX(' + QUOTENAME(@IDColumnName) + N') FROM ' + @SqlObjectName + N' WHERE ' + QUOTENAME(@DateColumnName) + ' < DATEADD(DAY,-1*@RetainDays,GETDATE());';

IF @Debug = 1
BEGIN
    PRINT @sql;
END;
-- Even in Debug mode, we run this to get min/max values. We're not changing data yet.
EXEC sp_executesql @stmt = @sql, @params = N'@RetainDays int, @ChunkID bigint OUT, @MaxID bigint OUT', @RetainDays = @RetainDays, @ChunkID = @ChunkID OUT, @MaxID = @MaxID OUT;

--
--Now loop through those values and delete 
--
WHILE @ChunkID < @MaxID
    BEGIN 
        SELECT @ChunkID = @ChunkID + @ChunkSize;
        
        SELECT @sql = N'DELETE TOP (@ChunkSize) x FROM ' + @SqlObjectName + N' AS x WHERE x.' + QUOTENAME(@IDColumnName) + N' < @ChunkID AND x.' + QUOTENAME(@IDColumnName) + N' < @MaxID;'
        --if we're not in debug mode, then run the delete
        IF @Debug = 0
            BEGIN
                EXEC sp_executesql @stmt = @sql, @params = N'@ChunkSize int, @ChunkID bigint, @MaxID bigint', @ChunkSize = @ChunkSize, @ChunkID = @ChunkID, @MaxID = @MaxID;
                WAITFOR DELAY @LoopWaitDateTime;
            END;
        --if we're in debug mode, just print the DELETE statement
        ELSE
            BEGIN
                PRINT @sql;
            END;
    END;
GO
