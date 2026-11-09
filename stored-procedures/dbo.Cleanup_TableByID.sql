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
        **The date/time column should be the date inserted**
          Every delete checks the same retention cutoff, even when IDs and timestamps are out of order.
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
     This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SET NOCOUNT ON;

IF @ChunkSize IS NULL OR @ChunkSize <= 0
BEGIN
    RAISERROR('@ChunkSize must be greater than zero.', 16, 1);
    RETURN;
END;

IF @RetainDays IS NULL OR @RetainDays < 0
BEGIN
    RAISERROR('@RetainDays must be zero or greater.', 16, 1);
    RETURN;
END;

DECLARE @Cutoff           datetime = DATEADD(DAY, -@RetainDays, GETDATE()),
        @MaxID            bigint,
        @RowsDeleted      int,
        @Sql              nvarchar(max),
        @LoopWaitDateTime datetime = @LoopWaitTime,
        @SqlObjectName    nvarchar(776) = QUOTENAME(@DbName) + N'.' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName),
        @QuotedID         nvarchar(258) = QUOTENAME(@IDColumnName),
        @QuotedDate       nvarchar(258) = QUOTENAME(@DateColumnName);

SET @Sql = N'SELECT @MaxID = MAX(' + @QuotedID + N')
FROM ' + @SqlObjectName + N'
WHERE ' + @QuotedDate + N' < @Cutoff;';
EXEC sys.sp_executesql @Sql, N'@Cutoff datetime, @MaxID bigint OUTPUT',
    @Cutoff = @Cutoff, @MaxID = @MaxID OUTPUT;

IF @MaxID IS NULL
    RETURN;

SET @Sql = N';WITH Batch AS (
    SELECT TOP (@ChunkSize) ' + @QuotedID + N'
    FROM ' + @SqlObjectName + N'
    WHERE ' + @QuotedID + N' <= @MaxID
      AND ' + @QuotedDate + N' < @Cutoff
    ORDER BY ' + @QuotedID + N'
)
DELETE FROM Batch;
SET @RowsDeleted = @@ROWCOUNT;';

IF @Debug = 1 OR @Debug IS NULL
BEGIN
    EXEC dbo.Debug_Print @DebugMessage = @Sql;
    SELECT Cutoff = @Cutoff, MaxID = @MaxID, ChunkSize = @ChunkSize;
    RETURN;
END;

WHILE 1 = 1
BEGIN
    EXEC sys.sp_executesql @Sql,
        N'@Cutoff datetime, @MaxID bigint, @ChunkSize int, @RowsDeleted int OUTPUT',
        @Cutoff = @Cutoff, @MaxID = @MaxID, @ChunkSize = @ChunkSize, @RowsDeleted = @RowsDeleted OUTPUT;

    IF @RowsDeleted < @ChunkSize
        BREAK;

    WAITFOR DELAY @LoopWaitDateTime;
END;
GO
