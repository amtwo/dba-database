CREATE OR ALTER PROCEDURE dbo.Check_QueryStore_HeavyHitters
    @DbNamePattern      nvarchar(300)     = NULL,
    @DatabaseList       nvarchar(max)     = NULL,
    @DbExcludePattern   nvarchar(300)     = NULL,
    @DbExcludeList      nvarchar(max)     = NULL,
    @WindowStart        datetimeoffset(7) = NULL,
    @WindowEnd          datetimeoffset(7) = NULL,
    @CompareOffsetHours int               = 168,
    @Top                int               = 25,
    @IncludeQuickieStoreAnalysis bit       = NULL,
    @Debug              bit               = 0
AS
/*************************************************************************************************
AUTHOR: Cody 🤖
DESCRIPTION
    Combines the top cumulative and positive-delta CPU, logical I/O, and execution-volume reports
    into one ranked list across the databases selected by dbo.sp_ineachdb. Each source report
    is ranked independently on a 0-100 scale. The CPU, I/O, and execution scores each use the
    better of their Cum and Delta ranks, and HeavyHitterScore is the equal-weight average of those
    three scores. This makes the ranking a transparent prioritization heuristic, not a comparison
    of raw CPU, I/O, and execution units. Delta reports use @WindowStart/@WindowEnd and compare
    against the same-length window @CompareOffsetHours earlier. Cum reports use all retained
    Query Store history when @WindowStart is NULL.

PARAMETERS
* @DbNamePattern - Database name pattern passed to dbo.sp_ineachdb.
* @DatabaseList - Explicit database list passed to dbo.sp_ineachdb.
* @DbExcludePattern - Database name exclusion pattern passed to dbo.sp_ineachdb.
* @DbExcludeList - Explicit database exclusion list passed to dbo.sp_ineachdb.
* @WindowStart - Start of the reporting window. NULL means all retained history for Cum reports;
  Delta reports default to one hour before @WindowEnd.
* @WindowEnd - End of the reporting window. Defaults to the current time.
* @CompareOffsetHours - Comparison-window offset for Delta reports. Defaults to 168 hours.
* @Top - Maximum rows requested from each source report per database and maximum rows returned.
* @IncludeQuickieStoreAnalysis - Run sp_QuickieStore for the returned query hashes. NULL runs it
  when it is installed in the current utility database, 0 skips it, and 1 requires it to be installed.
* @Debug - Print the assembled command and source-report SQL.

EXAMPLES:
-- Rank the top heavy hitters across all eligible databases:
-- EXEC dbo.Check_QueryStore_HeavyHitters;

-- Limit database scope, use a custom window, and return more candidates:
-- EXEC dbo.Check_QueryStore_HeavyHitters
--     @DbNamePattern = N'AM%',
--     @WindowStart = '2026-10-31T08:00:00-04:00',
--     @WindowEnd = '2026-10-31T10:00:00-04:00',
--     @CompareOffsetHours = 168,
--     @Top = 50;
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
**************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    SET @WindowEnd = ISNULL(@WindowEnd, SYSDATETIMEOFFSET());

    DECLARE @QuickieStoreInstalled bit = CASE WHEN EXISTS (
                SELECT 1
                FROM sys.procedures AS p
                JOIN sys.schemas AS s
                    ON s.schema_id = p.schema_id
                WHERE s.name = N'dbo'
                  AND p.name = N'sp_QuickieStore'
            ) THEN 1 ELSE 0 END;

    SET @IncludeQuickieStoreAnalysis = COALESCE(@IncludeQuickieStoreAnalysis, @QuickieStoreInstalled);

    IF @IncludeQuickieStoreAnalysis = 1 AND @QuickieStoreInstalled = 0
    BEGIN
        RAISERROR('sp_QuickieStore is not installed in the current utility database.', 16, 1);
        RETURN;
    END;

    CREATE TABLE #CpuCum
    (
        DatabaseName          sysname       NULL,
        query_hash            binary(8)     NULL,
        Execs                 bigint        NULL,
        CpuSec                decimal(18, 1) NULL,
        CpuMsPerExec          decimal(18, 2) NULL,
        LogicalIoPages        decimal(18, 1) NULL,
        LogicalIoPagesPerExec decimal(18, 2) NULL,
        SampleQueryId         bigint        NULL,
        ObjectName            nvarchar(512) NULL,
        SampleText            nvarchar(200) NULL
    );

    CREATE TABLE #CpuDelta
    (
        DatabaseName          sysname       NULL,
        query_hash            binary(8)     NULL,
        BaseExecs             bigint        NULL,
        NowExecs              bigint        NULL,
        BaseCpuSec            decimal(18, 1) NULL,
        NowCpuSec             decimal(18, 1) NULL,
        DeltaCpuSec           decimal(18, 1) NULL,
        NowCpuMsPerExec       decimal(18, 2) NULL,
        BaseCpuMsPerExec      decimal(18, 2) NULL,
        CpuPerExecRatio       decimal(18, 2) NULL,
        ExecRatio             decimal(18, 2) NULL,
        IsNewQuery            int           NULL,
        SampleQueryId         bigint        NULL,
        ObjectName            nvarchar(512) NULL,
        SampleText            nvarchar(200) NULL
    );

    CREATE TABLE #IoCum
    (
        DatabaseName          sysname       NULL,
        query_hash            binary(8)     NULL,
        Execs                 bigint        NULL,
        LogicalIoPages        decimal(18, 1) NULL,
        LogicalReads          decimal(18, 1) NULL,
        LogicalWrites         decimal(18, 1) NULL,
        PhysicalReads         decimal(18, 1) NULL,
        LogicalIoPagesPerExec decimal(18, 2) NULL,
        LogicalReadsPerExec   decimal(18, 2) NULL,
        LogicalWritesPerExec  decimal(18, 2) NULL,
        SampleQueryId         bigint        NULL,
        ObjectName            nvarchar(512) NULL,
        SampleText            nvarchar(200) NULL
    );

    CREATE TABLE #IoDelta
    (
        DatabaseName              sysname       NULL,
        query_hash                binary(8)     NULL,
        BaseExecs                 bigint        NULL,
        NowExecs                  bigint        NULL,
        BaseLogicalIoPages        decimal(18, 1) NULL,
        NowLogicalIoPages         decimal(18, 1) NULL,
        DeltaLogicalIoPages       decimal(18, 1) NULL,
        BaseLogicalReads          decimal(18, 1) NULL,
        NowLogicalReads           decimal(18, 1) NULL,
        DeltaLogicalReads         decimal(18, 1) NULL,
        BaseLogicalWrites         decimal(18, 1) NULL,
        NowLogicalWrites          decimal(18, 1) NULL,
        DeltaLogicalWrites        decimal(18, 1) NULL,
        BasePhysicalReads         decimal(18, 1) NULL,
        NowPhysicalReads          decimal(18, 1) NULL,
        DeltaPhysicalReads        decimal(18, 1) NULL,
        NowLogicalIoPagesPerExec  decimal(18, 2) NULL,
        BaseLogicalIoPagesPerExec decimal(18, 2) NULL,
        IoPerExecRatio            decimal(18, 2) NULL,
        ExecRatio                 decimal(18, 2) NULL,
        IsNewQuery                int           NULL,
        SampleQueryId             bigint        NULL,
        ObjectName                nvarchar(512) NULL,
        SampleText                nvarchar(200) NULL
    );

    CREATE TABLE #ExecutionCum
    (
        DatabaseName              sysname       NULL,
        query_hash                binary(8)     NULL,
        Execs                     bigint        NULL,
        CpuSec                    decimal(18, 1) NULL,
        LogicalIoPages            decimal(18, 1) NULL,
        CpuMsPerExec              decimal(18, 2) NULL,
        LogicalIoPagesPerExec     decimal(18, 2) NULL,
        SampleQueryId             bigint        NULL,
        ObjectName                nvarchar(512) NULL,
        SampleText                nvarchar(200) NULL
    );

    CREATE TABLE #ExecutionDelta
    (
        DatabaseName              sysname       NULL,
        query_hash                binary(8)     NULL,
        BaseExecs                 bigint        NULL,
        NowExecs                  bigint        NULL,
        DeltaExecs                bigint        NULL,
        ExecRatio                 decimal(18, 2) NULL,
        IsNewQuery                int           NULL,
        NowCpuMsPerExec           decimal(18, 2) NULL,
        BaseCpuMsPerExec          decimal(18, 2) NULL,
        CpuPerExecRatio           decimal(18, 2) NULL,
        NowLogicalIoPagesPerExec  decimal(18, 2) NULL,
        BaseLogicalIoPagesPerExec decimal(18, 2) NULL,
        IoPerExecRatio            decimal(18, 2) NULL,
        SampleQueryId             bigint        NULL,
        ObjectName                nvarchar(512) NULL,
        SampleText                nvarchar(200) NULL
    );

    DECLARE @Command nvarchar(max),
            @WindowStartSql nvarchar(40) = COALESCE(QUOTENAME(CONVERT(nvarchar(35), @WindowStart, 127), ''''), N'NULL'),
            @WindowEndSql   nvarchar(40) = QUOTENAME(CONVERT(nvarchar(35), @WindowEnd, 127), '''');

    SET @Command = N'
SET NOCOUNT ON;
DECLARE @CurrentDatabase sysname = DB_NAME(),
        @WindowStart datetimeoffset(7) = ' + @WindowStartSql + N',
        @WindowEnd datetimeoffset(7) = ' + @WindowEndSql + N',
        @CompareOffsetHours int = ' + CONVERT(nvarchar(12), @CompareOffsetHours) + N',
        @Top int = ' + CONVERT(nvarchar(12), @Top) + N',
        @Debug bit = ' + CONVERT(nvarchar(1), @Debug) + N';

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @CurrentDatabase AND is_query_store_on = 1)
BEGIN
    INSERT INTO #CpuCum (DatabaseName, query_hash, Execs, CpuSec, CpuMsPerExec, LogicalIoPages, LogicalIoPagesPerExec, SampleQueryId, ObjectName, SampleText)
    EXEC ' + QUOTENAME(DB_NAME()) + N'.dbo.QueryStore_TopCpuCum
        @DatabaseName = @CurrentDatabase,
        @WindowStart  = @WindowStart,
        @WindowEnd    = @WindowEnd,
        @Top          = @Top,
        @Debug        = @Debug;

    INSERT INTO #CpuDelta (DatabaseName, query_hash, BaseExecs, NowExecs, BaseCpuSec, NowCpuSec, DeltaCpuSec, NowCpuMsPerExec, BaseCpuMsPerExec, CpuPerExecRatio, ExecRatio, IsNewQuery, SampleQueryId, ObjectName, SampleText)
    EXEC ' + QUOTENAME(DB_NAME()) + N'.dbo.QueryStore_TopCpuDelta
        @DatabaseName       = @CurrentDatabase,
        @WindowStart        = @WindowStart,
        @WindowEnd          = @WindowEnd,
        @CompareOffsetHours = @CompareOffsetHours,
        @Top                = @Top,
        @Debug              = @Debug;

    INSERT INTO #IoCum (DatabaseName, query_hash, Execs, LogicalIoPages, LogicalReads, LogicalWrites, PhysicalReads, LogicalIoPagesPerExec, LogicalReadsPerExec, LogicalWritesPerExec, SampleQueryId, ObjectName, SampleText)
    EXEC ' + QUOTENAME(DB_NAME()) + N'.dbo.QueryStore_TopIoCum
        @DatabaseName = @CurrentDatabase,
        @WindowStart  = @WindowStart,
        @WindowEnd    = @WindowEnd,
        @Top          = @Top,
        @Debug        = @Debug;

    INSERT INTO #IoDelta (DatabaseName, query_hash, BaseExecs, NowExecs, BaseLogicalIoPages, NowLogicalIoPages, DeltaLogicalIoPages, BaseLogicalReads, NowLogicalReads, DeltaLogicalReads, BaseLogicalWrites, NowLogicalWrites, DeltaLogicalWrites, BasePhysicalReads, NowPhysicalReads, DeltaPhysicalReads, NowLogicalIoPagesPerExec, BaseLogicalIoPagesPerExec, IoPerExecRatio, ExecRatio, IsNewQuery, SampleQueryId, ObjectName, SampleText)
    EXEC ' + QUOTENAME(DB_NAME()) + N'.dbo.QueryStore_TopIoDelta
        @DatabaseName       = @CurrentDatabase,
        @WindowStart        = @WindowStart,
        @WindowEnd          = @WindowEnd,
        @CompareOffsetHours = @CompareOffsetHours,
        @Top                = @Top,
        @Debug              = @Debug;

    INSERT INTO #ExecutionCum (DatabaseName, query_hash, Execs, CpuSec, LogicalIoPages, CpuMsPerExec, LogicalIoPagesPerExec, SampleQueryId, ObjectName, SampleText)
    EXEC ' + QUOTENAME(DB_NAME()) + N'.dbo.QueryStore_TopExecutionCum
        @DatabaseName = @CurrentDatabase,
        @WindowStart  = @WindowStart,
        @WindowEnd    = @WindowEnd,
        @Top          = @Top,
        @Debug        = @Debug;

    INSERT INTO #ExecutionDelta (DatabaseName, query_hash, BaseExecs, NowExecs, DeltaExecs, ExecRatio, IsNewQuery, NowCpuMsPerExec, BaseCpuMsPerExec, CpuPerExecRatio, NowLogicalIoPagesPerExec, BaseLogicalIoPagesPerExec, IoPerExecRatio, SampleQueryId, ObjectName, SampleText)
    EXEC ' + QUOTENAME(DB_NAME()) + N'.dbo.QueryStore_TopExecutionDelta
        @DatabaseName       = @CurrentDatabase,
        @WindowStart        = @WindowStart,
        @WindowEnd          = @WindowEnd,
        @CompareOffsetHours = @CompareOffsetHours,
        @Top                = @Top,
        @Debug              = @Debug;
END;';

    IF @Debug = 1
        EXEC dbo.Debug_Print @DebugMessage = @Command;

    EXEC dbo.sp_ineachdb
        @command         = @Command,
        @name_pattern    = @DbNamePattern,
        @database_list   = @DatabaseList,
        @exclude_pattern = @DbExcludePattern,
        @exclude_list    = @DbExcludeList;

    CREATE TABLE #SourceRanks
    (
        DatabaseName sysname       NOT NULL,
        query_hash   binary(8)     NOT NULL,
        SourceName   varchar(20)   NOT NULL,
        MetricValue  float         NULL,
        ReportRank   bigint        NOT NULL,
        ReportRows   bigint        NOT NULL,
        RankScore    decimal(9, 2) NOT NULL
    );

    ;WITH SourceMetrics AS (
        SELECT DatabaseName, query_hash, SourceName = 'CpuCum', MetricValue = CONVERT(float, CpuSec)
        FROM #CpuCum
        UNION ALL
        SELECT DatabaseName, query_hash, 'CpuDelta', CONVERT(float, DeltaCpuSec)
        FROM #CpuDelta
        WHERE DeltaCpuSec > 0
        UNION ALL
        SELECT DatabaseName, query_hash, 'IoCum', CONVERT(float, LogicalIoPages)
        FROM #IoCum
        UNION ALL
        SELECT DatabaseName, query_hash, 'IoDelta', CONVERT(float, DeltaLogicalIoPages)
        FROM #IoDelta
        WHERE DeltaLogicalIoPages > 0
        UNION ALL
        SELECT DatabaseName, query_hash, 'ExecutionCum', CONVERT(float, Execs)
        FROM #ExecutionCum
        UNION ALL
        SELECT DatabaseName, query_hash, 'ExecutionDelta', CONVERT(float, DeltaExecs)
        FROM #ExecutionDelta
        WHERE DeltaExecs > 0
    ),
    Ranked AS (
        SELECT
            sm.DatabaseName,
            sm.query_hash,
            sm.SourceName,
            sm.MetricValue,
            ReportRank = RANK() OVER (PARTITION BY sm.SourceName ORDER BY sm.MetricValue DESC),
            ReportRows = COUNT_BIG(*) OVER (PARTITION BY sm.SourceName)
        FROM SourceMetrics AS sm
    )
    INSERT INTO #SourceRanks (DatabaseName, query_hash, SourceName, MetricValue, ReportRank, ReportRows, RankScore)
    SELECT
        r.DatabaseName,
        r.query_hash,
        r.SourceName,
        r.MetricValue,
        r.ReportRank,
        r.ReportRows,
        RankScore = CONVERT(decimal(9, 2), CASE
            WHEN r.ReportRows = 1 THEN 100.0
            ELSE 100.0 * (r.ReportRows - r.ReportRank) / NULLIF(r.ReportRows - 1, 0)
        END)
    FROM Ranked AS r;

    ;WITH PerQuery AS (
        SELECT
            sr.DatabaseName,
            sr.query_hash,
            CpuCumRankScore      = MAX(CASE WHEN sr.SourceName = 'CpuCum' THEN sr.RankScore END),
            CpuDeltaRankScore    = MAX(CASE WHEN sr.SourceName = 'CpuDelta' THEN sr.RankScore END),
            IoCumRankScore       = MAX(CASE WHEN sr.SourceName = 'IoCum' THEN sr.RankScore END),
            IoDeltaRankScore     = MAX(CASE WHEN sr.SourceName = 'IoDelta' THEN sr.RankScore END),
            ExecutionCumRankScore = MAX(CASE WHEN sr.SourceName = 'ExecutionCum' THEN sr.RankScore END),
            ExecutionDeltaRankScore = MAX(CASE WHEN sr.SourceName = 'ExecutionDelta' THEN sr.RankScore END)
        FROM #SourceRanks AS sr
        GROUP BY sr.DatabaseName, sr.query_hash
    ),
    Scores AS (
        SELECT
            pq.*,
            CpuScore = CASE WHEN ISNULL(pq.CpuCumRankScore, 0) >= ISNULL(pq.CpuDeltaRankScore, 0)
                            THEN ISNULL(pq.CpuCumRankScore, 0) ELSE ISNULL(pq.CpuDeltaRankScore, 0) END,
            IoScore = CASE WHEN ISNULL(pq.IoCumRankScore, 0) >= ISNULL(pq.IoDeltaRankScore, 0)
                           THEN ISNULL(pq.IoCumRankScore, 0) ELSE ISNULL(pq.IoDeltaRankScore, 0) END,
            ExecutionScore = CASE WHEN ISNULL(pq.ExecutionCumRankScore, 0) >= ISNULL(pq.ExecutionDeltaRankScore, 0)
                                  THEN ISNULL(pq.ExecutionCumRankScore, 0) ELSE ISNULL(pq.ExecutionDeltaRankScore, 0) END
        FROM PerQuery AS pq
    )
    SELECT TOP (@Top)
        s.DatabaseName,
        s.query_hash,
        HeavyHitterScore = CONVERT(decimal(9, 2), (s.CpuScore + s.IoScore + s.ExecutionScore) / 3.0),
        s.CpuScore,
        s.IoScore,
        s.ExecutionScore,
        s.CpuCumRankScore,
        s.CpuDeltaRankScore,
        s.IoCumRankScore,
        s.IoDeltaRankScore,
        s.ExecutionCumRankScore,
        s.ExecutionDeltaRankScore,
        CpuCumSec          = cc.CpuSec,
        CpuDeltaSec        = cd.DeltaCpuSec,
        IoCumPages         = ic.LogicalIoPages,
        IoDeltaPages       = id.DeltaLogicalIoPages,
        ExecutionCumCount  = ec.Execs,
        ExecutionDelta     = ed.DeltaExecs,
        CpuCumMsPerExec    = cc.CpuMsPerExec,
        CpuDeltaPerExecRatio = cd.CpuPerExecRatio,
        IoCumPagesPerExec  = ic.LogicalIoPagesPerExec,
        IoDeltaPerExecRatio = id.IoPerExecRatio,
        ExecutionCumCpuMsPerExec = ec.CpuMsPerExec,
        ExecutionCumIoPagesPerExec = ec.LogicalIoPagesPerExec,
        ExecutionDeltaCpuPerExecRatio = ed.CpuPerExecRatio,
        ExecutionDeltaIoPerExecRatio = ed.IoPerExecRatio,
        SampleQueryId = COALESCE(cc.SampleQueryId, cd.SampleQueryId, ic.SampleQueryId, id.SampleQueryId, ec.SampleQueryId, ed.SampleQueryId),
        ObjectName    = COALESCE(cc.ObjectName, cd.ObjectName, ic.ObjectName, id.ObjectName, ec.ObjectName, ed.ObjectName),
        SampleText    = COALESCE(cc.SampleText, cd.SampleText, ic.SampleText, id.SampleText, ec.SampleText, ed.SampleText),
        QuickieStoreCommand = N'EXEC ' + QUOTENAME(DB_NAME()) + N'.dbo.sp_QuickieStore @database_name = N'
            + QUOTENAME(s.DatabaseName, NCHAR(39))
            + N', @include_query_hashes = N'
            + QUOTENAME(CONVERT(nvarchar(18), s.query_hash, 1), NCHAR(39))
            + N', @sort_order = N''total cpu'', @expert_mode = 1'
            + N', @start_date = '
            + QUOTENAME(COALESCE(CONVERT(nvarchar(35), @WindowStart, 127), N'1753-01-01T00:00:00+00:00'), NCHAR(39))
            + N', @end_date = '
            + QUOTENAME(CONVERT(nvarchar(35), @WindowEnd, 127), NCHAR(39))
            + N';'
    INTO #HeavyHitters
    FROM Scores AS s
    LEFT JOIN #CpuCum AS cc
        ON cc.DatabaseName = s.DatabaseName AND cc.query_hash = s.query_hash
    LEFT JOIN #CpuDelta AS cd
        ON cd.DatabaseName = s.DatabaseName AND cd.query_hash = s.query_hash
    LEFT JOIN #IoCum AS ic
        ON ic.DatabaseName = s.DatabaseName AND ic.query_hash = s.query_hash
    LEFT JOIN #IoDelta AS id
        ON id.DatabaseName = s.DatabaseName AND id.query_hash = s.query_hash
    LEFT JOIN #ExecutionCum AS ec
        ON ec.DatabaseName = s.DatabaseName AND ec.query_hash = s.query_hash
    LEFT JOIN #ExecutionDelta AS ed
        ON ed.DatabaseName = s.DatabaseName AND ed.query_hash = s.query_hash
    ORDER BY HeavyHitterScore DESC, s.CpuScore DESC, s.IoScore DESC, s.ExecutionScore DESC,
             s.DatabaseName, s.query_hash;

    SELECT
        hh.DatabaseName,
        hh.query_hash,
        hh.HeavyHitterScore,
        hh.CpuScore,
        hh.IoScore,
        hh.ExecutionScore,
        hh.CpuCumRankScore,
        hh.CpuDeltaRankScore,
        hh.IoCumRankScore,
        hh.IoDeltaRankScore,
        hh.ExecutionCumRankScore,
        hh.ExecutionDeltaRankScore,
        hh.CpuCumSec,
        hh.CpuDeltaSec,
        hh.IoCumPages,
        hh.IoDeltaPages,
        hh.ExecutionCumCount,
        hh.ExecutionDelta,
        hh.CpuCumMsPerExec,
        hh.CpuDeltaPerExecRatio,
        hh.IoCumPagesPerExec,
        hh.IoDeltaPerExecRatio,
        hh.ExecutionCumCpuMsPerExec,
        hh.ExecutionCumIoPagesPerExec,
        hh.ExecutionDeltaCpuPerExecRatio,
        hh.ExecutionDeltaIoPerExecRatio,
        hh.SampleQueryId,
        hh.ObjectName,
        hh.SampleText,
        hh.QuickieStoreCommand
    FROM #HeavyHitters AS hh
    ORDER BY HeavyHitterScore DESC, CpuScore DESC, IoScore DESC, ExecutionScore DESC,
             DatabaseName, query_hash;

    IF @IncludeQuickieStoreAnalysis = 1 AND EXISTS (SELECT 1 FROM #HeavyHitters)
    BEGIN
        /*QuickieStore accepts comma-separated hash filters up to 4,000 characters.
          Batch at 200 hashes so every call stays below that limit.*/
        SELECT
            hh.DatabaseName,
            hh.query_hash,
            BatchNumber = CONVERT(int, (ROW_NUMBER() OVER (PARTITION BY hh.DatabaseName ORDER BY hh.query_hash) - 1) / 200)
        INTO #QuickieStoreQueries
        FROM #HeavyHitters AS hh;

        DECLARE @QuickieStoreProc nvarchar(400) = QUOTENAME(DB_NAME()) + N'.dbo.sp_QuickieStore',
                @QuickieDatabase sysname,
                @QuickieBatch int,
                @QuickieHashes nvarchar(4000),
                @QuickieStart datetimeoffset(7) = COALESCE(@WindowStart, CONVERT(datetimeoffset(7), '1753-01-01T00:00:00+00:00'));

        DECLARE QuickieStoreCursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT DatabaseName, BatchNumber
            FROM #QuickieStoreQueries
            ORDER BY DatabaseName, BatchNumber;

        OPEN QuickieStoreCursor;
        FETCH NEXT FROM QuickieStoreCursor INTO @QuickieDatabase, @QuickieBatch;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @QuickieHashes = STUFF((
                SELECT N',' + CONVERT(nvarchar(18), q.query_hash, 1)
                FROM #QuickieStoreQueries AS q
                WHERE q.DatabaseName = @QuickieDatabase
                  AND q.BatchNumber = @QuickieBatch
                ORDER BY q.query_hash
                FOR XML PATH(''), TYPE
            ).value('.', 'nvarchar(max)'), 1, 1, N'');

            EXEC @QuickieStoreProc
                @database_name = @QuickieDatabase,
                @include_query_hashes = @QuickieHashes,
                @sort_order = 'total cpu',
                @top = @Top,
                @start_date = @QuickieStart,
                @end_date = @WindowEnd,
                @expert_mode = 1,
                @hide_help_table = 1;

            FETCH NEXT FROM QuickieStoreCursor INTO @QuickieDatabase, @QuickieBatch;
        END;

        CLOSE QuickieStoreCursor;
        DEALLOCATE QuickieStoreCursor;
    END;
END;
GO
