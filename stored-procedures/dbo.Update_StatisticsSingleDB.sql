CREATE OR ALTER PROCEDURE dbo.Update_StatisticsSingleDB
    @DbName                     sysname,
    @MediumRowCountThreshold    bigint   = NULL,          -- rows >= this -> Medium bucket
    @LargeRowCountThreshold     bigint   = NULL,          -- rows >= this -> Large bucket
    @SmallTableSamplePercent    tinyint  = NULL,          -- Small bucket sample (100 = FULLSCAN)
    @MediumTableSamplePercent   tinyint  = NULL,          -- Medium bucket sample (100 = FULLSCAN)
    @LargeTableSamplePercent    tinyint  = NULL,          -- Large bucket sample
    @Buckets                    varchar(50) = NULL,       -- which size buckets to run; NULL = all (Small,Medium,Large)
    @SkewAnalysis               bit      = NULL,          -- 1 = bump skewed Medium/Large tables down a bucket
    @SkewRatioCutoff            decimal(10,2) = NULL,     -- max/avg histogram step ratio considered skewed
    @DisableAutoStatsThreshold  bigint   = NULL,          -- rows >= this -> sp_autostats OFF; NULL = never lock
    @StatisticsModificationLevel int     = NULL,          -- passthrough to the normal pass; NULL = update if modified
    @LogToTable                 bit      = NULL,          -- log Ola commands to dbo.CommandLog
    @Debug                      bit      = 0              -- 1 = print everything we'd run, change nothing
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260601
    Config-driven driver around unmodified Ola Hallengren IndexOptimize, for a SINGLE database.
    dbo.Update_Statistics is a thin multi-database wrapper over this proc (it resolves an Ola-style
    @DbList and calls this once per database); run this one directly when you want a single database.
    This proc makes the per-table decisions IndexOptimize cannot make on its own, then hands the
    actual work to Ola so we never fork his code:

      1. DYNAMIC SAMPLE SIZE. Every table in @DbName is bucketed by allocated row count into
         Small / Medium / Large using two thresholds, and each bucket gets its own sample percent
         (100 = FULLSCAN). The premise: on big volatile tables, a weekly-ish high
         sample beats a fresh sub-1% auto-stats update, so we scan small tables fully and sample
         the giants.

      2. AUTO-STATS LOCKING. Tables at/above @DisableAutoStatsThreshold get AUTO_UPDATE_STATISTICS
         turned OFF (via sys.sp_autostats), so a tiny-sample auto-update can't trample the
         high-sample update we just did. NORECOMPUTE is a commitment: a locked table MUST be
         guaranteed on a scheduled refresh, which is exactly what this proc -- run nightly -- is.

      3. SKEW-AWARE BUCKETING (optional, @SkewAnalysis = 1). A sampled histogram misrepresents a
         lopsided (skewed) column far worse than an evenly-distributed one, so a skewed table wants
         a bigger sample than its row count alone would buy. When a Medium or Large table is found
         to be skewed (max/avg histogram step ratio > @SkewRatioCutoff, the same measure
         dbo.Check_StatsDetails reports), we bump it down ONE bucket -- Large -> Medium,
         Medium -> Small -- so it rides the next-larger sample percent. The bump is recomputed from
         row count every run, so it never compounds (a Large table is always re-derived as Large,
         then bumped to Medium); it just rides a larger sample for as long as the skew persists.
         Small tables are never analyzed: there is no larger-sample bucket to bump them into, and
         the default Small sample is already FULLSCAN.

    WHERE THE KNOBS COME FROM (config, with a per-table exception list):
    * PER-SERVER DEFAULTS. Any parameter left NULL is sourced from dbo.Config (category
      'StatisticsMaint') via dbo.Config_Get, falling back to a built-in default when there's no
      Config row. So the same code behaves differently per server purely from data, and an explicit
      parameter still wins (handy for testing). A missing Config row for a "never" knob
      (@DisableAutoStatsThreshold / @StatisticsModificationLevel) leaves it NULL = off.
    * PER-TABLE OVERRIDES. A single 'STATOVERRIDE' Config row holds a JSON array of sparse
      per-table exceptions for the handful of tables the automatic bucketing gets wrong. Each entry
      is { db, schema, table } plus any of:
         "exclude": true   -- skip this table entirely (and never lock it; if it was locked on an
                           --   earlier run, it is UN-locked here -- handed back to auto-stats -- so
                           --   it can't end up locked AND unrefreshed = frozen)
         "sample": 1..100  -- force this table's sample percent, ignoring its bucket
         "bucket": "Small"|"Medium"|"Large"  -- force the bucket, ignoring row count (and skew)
         "lock": true|false -- force auto-stats OFF (true) or force-exempt (false), overriding the
                               per-server @DisableAutoStatsThreshold for this table
      An absent field means "no opinion, use the computed default." This replaces the hand-built
      include/exclude lists the old per-group Agent jobs carried. "lock" still respects the hard
      preconditions: a table with no auto-updating stat, a memory-optimized table, or an excluded
      table is never locked regardless of "lock":true.
      "table" is matched with LIKE, so "%old" targets every table whose name ends in "old" (the
      wildcard shape the old Ola exclusion tokens used); "schema" is matched exactly. Because it is
      raw LIKE, _ [ and % are WILDCARDS: an override of "Order_Detail" also matches "OrderXDetail"
      (the _ is "any one char"). To target a real table whose name contains one of those characters
      literally, bracket-escape it, e.g. "Order[_]Detail". When both an exact-name and a wildcard
      entry match one table, the EXACT one wins for sample/bucket; exclude=true from ANY match wins.
      Two wildcards giving different sample/bucket for the same table with no exact tiebreak is an
      error, not a silent pick.

    HOW IT COOPERATES WITH IndexOptimize:
    * sp_autostats only flips the metadata flag; it runs no UPDATE STATISTICS. Ola then owns every
      actual update, which PRESERVES the existing no_recompute flag (it re-emits NORECOMPUTE),
      so once locked a table stays locked across every future run.
    * The run a table is first locked, its modification_counter may be 0, and
      EXEC dbo.IndexOptimize @OnlyModifiedStatistics='Y' SKIPS counter-0 stats -- which would
      freeze a freshly-locked table at whatever (possibly tiny) sample it last had. So newly-locked
      tables get a separate FORCED pass (@OnlyModifiedStatistics='N',
      @StatisticsModificationLevel=NULL -- the only combination that updates a counter-0 stat).
      Every later run they ride the normal pass.

    EXECUTION SHAPE:
    * Up front : sp_autostats OFF for new lock candidates -> the "newly locked this run" set;
                 sp_autostats ON for any excluded table still carrying a locked stat (un-lock, so an
                 exclude of a previously-locked table can't leave it locked-and-unrefreshed).
    * Forced   : @OnlyModifiedStatistics='N', for newly-locked tables, grouped by sample percent.
    * Normal   : everything else, grouped by sample percent. Small tables that ride the default
                 Small sample run as ALL_INDEXES minus the Medium/Large/newly-locked/excluded/
                 sample-overridden tables (Ola exclusion syntax), so we never enumerate the
                 thousands of small tables. A Small table carrying its own sample override is
                 promoted OUT of the ALL_INDEXES sweep into its own explicit pass.

    BUCKET SCHEDULING (@Buckets):
    * The full worklist -- bucketing, skew, locking, unlock -- is always computed; @Buckets only
      controls which passes actually EXECUTE. Name a subset (e.g. 'Large') to update just those size
      buckets this run, so large tables can be scheduled on a slower cadence than small ones. Each
      pass is tied to one size bucket; a pass whose bucket is not selected is skipped.
    * EXCEPTION: forced (newly-locked) passes always run regardless of @Buckets. A table locked this
      run must get its baseline refresh, so bucket scheduling can never leave a just-locked table
      frozen. (Corollary of the NORECOMPUTE promise, now per bucket: if you lock tables in a bucket,
      that bucket must stay on a schedule that runs often enough to keep them fresh.)

    This is a GENERIC wrapper: all policy lives in dbo.Config data, not in the code. Stock
    IndexOptimize and dbo.Config_Get are dependencies. See the repo README.

    SCOPE / ASSUMPTIONS:
    * Operates on a single database (@DbName) and on user tables (type = 'U'). Indexed views and
      memory-optimized tables are not locked (sp_autostats can't lock a memory-optimized table).
    * dbo.Config.NumericValue is numeric(16,6), so a per-server threshold sourced from Config tops
      out around 9.9 billion rows.


PARAMETERS
* @DbName - Target database. Validated; dbo.IndexOptimize must exist in the current database.
* @MediumRowCountThreshold - Allocated row count at/above which a table is at least Medium.
* @LargeRowCountThreshold - Allocated row count at/above which a table is Large. Must be >= Medium.
* @SmallTableSamplePercent - Sample percent for the Small bucket. 100 = FULLSCAN.
* @MediumTableSamplePercent - Sample percent for the Medium bucket. 100 = FULLSCAN.
* @LargeTableSamplePercent - Sample percent for the Large bucket.
* @Buckets - Comma-separated size buckets to process this run: any of Small, Medium, Large
             (case-insensitive). NULL or empty = all three (the normal case). Use a subset to run
             one size class on its own cadence, e.g. @Buckets = 'Large'. Forced refreshes of tables
             locked this run always execute regardless of @Buckets (see BUCKET SCHEDULING above).
* @SkewAnalysis - 1 reads histograms for Medium/Large tables and bumps any skewed table down one
                  bucket (Large->Medium, Medium->Small) so it gets the next-larger sample percent.
                  0 (default) skips the histogram read entirely. A table with an explicit bucket
                  override is never skew-bumped.
* @SkewRatioCutoff - Max-step-to-average-step histogram ratio at/above which a table is treated as
                  skewed. Matches the SkewRatio measure in dbo.Check_StatsDetails. Only used when
                  @SkewAnalysis = 1.
* @DisableAutoStatsThreshold - Row count at/above which AUTO_UPDATE_STATISTICS is turned OFF.
                               Orthogonal to the bucket thresholds, on purpose: "what sample" and
                               "who gets locked" are independent knobs. NULL locks nothing. An
                               excluded table is never locked (locking without a refresh = frozen).
* @StatisticsModificationLevel - Optional dynamic modification threshold passed to the NORMAL pass
                               (Ola's @StatisticsModificationLevel). NULL = update any modified stat.
                               When supplied, the normal pass uses @OnlyModifiedStatistics='N'
                               because Ola forbids combining the two. The forced pass ignores this.
* @LogToTable - 1 logs every Ola command to dbo.CommandLog (@LogToTable='Y').
* @Debug - 1 prints the worklist, the sp_autostats calls, and every IndexOptimize call, and
           changes nothing.

  Every knob above except @DbName / @Buckets / @Debug defaults to NULL and is resolved from
  dbo.Config (category 'StatisticsMaint') when not passed; an explicit value always wins. @Buckets
  is a per-run scheduling control (which passes execute), not a Config-backed policy value.

EXAMPLES:
-- Fully config-driven (the normal case -- the Agent job step is just this):
-- EXEC dbo.Update_StatisticsSingleDB @DbName = N'MyDb';

-- Large tables only (e.g. a slower weekly cadence for the giants):
-- EXEC dbo.Update_StatisticsSingleDB @DbName = N'MyDb', @Buckets = N'Large';

-- Small + medium tables (the nightly cadence, giants handled separately):
-- EXEC dbo.Update_StatisticsSingleDB @DbName = N'MyDb', @Buckets = N'Small,Medium';

-- See exactly what it would do, without touching anything:
-- EXEC dbo.Update_StatisticsSingleDB @DbName = N'MyDb', @Debug = 1;

-- Override the config for a one-off run: FULLSCAN small+medium, 50% giants, lock anything >= 100M:
-- EXEC dbo.Update_StatisticsSingleDB
--     @DbName = N'MyDb',
--     @MediumRowCountThreshold = 1000000,
--     @LargeRowCountThreshold = 100000000,
--     @LargeTableSamplePercent = 50,
--     @DisableAutoStatsThreshold = 100000000;

-- Skew-aware: 100/100/50 buckets, but a skewed Large table rides the 100% Medium sample instead of 50%:
-- EXEC dbo.Update_StatisticsSingleDB @DbName = N'MyDb', @SkewAnalysis = 1, @SkewRatioCutoff = 100.00;

**************************************************************************************************
MODIFICATIONS:
    20260629 - AM2 - Initial version. Config-driven wrapper around stock Ola IndexOptimize.
    20260629 - AM2 - Add optional skew-aware bucketing (@SkewAnalysis, @SkewRatioCutoff): a skewed
                     Medium/Large table is bumped down one bucket to ride a larger sample percent.
    20260713 - AM2 - Source per-server defaults from dbo.Config (via dbo.Config_Get); params now
                     default NULL and resolve config -> built-in fallback. Add per-table overrides
                     (exclude / force sample / force bucket) read from the 'STATOVERRIDE' JSON row.
                     Pass assembly now groups by effective sample so per-table samples work; a
                     small table with a sample override is promoted out of the ALL_INDEXES sweep.
    20260716 - AM2 - Rename to Update_StatisticsSingleDB (multi-DB wrapper is dbo.Update_Statistics).
    20260716 - AM2 - Add @Buckets: run only selected size buckets (Small/Medium/Large) this run so a
                     size class can be scheduled on its own cadence. Passes now carry their bucket and
                     are filtered at execution; forced (newly-locked) passes always run.
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    -------------------------------------------------------------------------------------------
    -- Guard clauses. Fail early and loudly on anything that would make the run nonsensical.
    -------------------------------------------------------------------------------------------
    IF DB_ID(@DbName) IS NULL
    BEGIN
        RAISERROR('Database %s not found on this instance.', 16, 1, @DbName);
        RETURN;
    END;

    -- This wrapper drives STOCK Ola IndexOptimize; it must already be installed in this database.
    IF OBJECT_ID(N'dbo.IndexOptimize', N'P') IS NULL
    BEGIN
        RAISERROR('dbo.IndexOptimize was not found in the current database. Install Ola Hallengren''s IndexOptimize before running this wrapper.', 16, 1);
        RETURN;
    END;

    -------------------------------------------------------------------------------------------
    -- Resolve per-server defaults. Any parameter left NULL is filled from dbo.Config
    -- (category 'StatisticsMaint'), then a built-in fallback. An explicitly-passed value always
    -- wins. Read the whole category once, then resolve each knob from it -- one round trip, not ten.
    -- The two "never" knobs have NO built-in fallback, so an absent Config row leaves them NULL.
    -------------------------------------------------------------------------------------------
    DECLARE @cfg TABLE (
        ConfigCode   varchar(16)   NOT NULL PRIMARY KEY,
        NumericValue numeric(16,6) NULL,
        UnicodeValue nvarchar(max) NULL
    );

    -- Guard the read so a server without dbo.Config still runs on the built-in fallbacks.
    IF OBJECT_ID(N'dbo.Config', N'U') IS NOT NULL
        INSERT INTO @cfg (ConfigCode, NumericValue, UnicodeValue)
        SELECT ConfigCode, NumericValue, UnicodeValue
        FROM dbo.Config_Get(N'StatisticsMaint', NULL);

    SET @MediumRowCountThreshold    = COALESCE(@MediumRowCountThreshold,    (SELECT NumericValue FROM @cfg WHERE ConfigCode = 'STATMEDROWS'), 1000000);
    SET @LargeRowCountThreshold     = COALESCE(@LargeRowCountThreshold,     (SELECT NumericValue FROM @cfg WHERE ConfigCode = 'STATLRGROWS'), 100000000);
    SET @SmallTableSamplePercent    = COALESCE(@SmallTableSamplePercent,    (SELECT NumericValue FROM @cfg WHERE ConfigCode = 'STATSMPSML'), 100);
    SET @MediumTableSamplePercent   = COALESCE(@MediumTableSamplePercent,   (SELECT NumericValue FROM @cfg WHERE ConfigCode = 'STATSMPMED'), 100);
    SET @LargeTableSamplePercent    = COALESCE(@LargeTableSamplePercent,    (SELECT NumericValue FROM @cfg WHERE ConfigCode = 'STATSMPLRG'), 50);
    SET @SkewAnalysis               = COALESCE(@SkewAnalysis,               (SELECT NumericValue FROM @cfg WHERE ConfigCode = 'STATSKEW'), 0);
    SET @SkewRatioCutoff            = COALESCE(@SkewRatioCutoff,            (SELECT NumericValue FROM @cfg WHERE ConfigCode = 'STATSKEWCUT'), 100.00);
    SET @LogToTable                 = COALESCE(@LogToTable,                 (SELECT NumericValue FROM @cfg WHERE ConfigCode = 'STATLOGTBL'), 1);
    -- "Never" knobs: no built-in fallback -> absent Config row keeps them NULL (feature off).
    SET @DisableAutoStatsThreshold   = COALESCE(@DisableAutoStatsThreshold,   (SELECT NumericValue FROM @cfg WHERE ConfigCode = 'STATLOCKROW'));
    SET @StatisticsModificationLevel = COALESCE(@StatisticsModificationLevel, (SELECT NumericValue FROM @cfg WHERE ConfigCode = 'STATMODLVL'));

    -- Validate the resolved values (so a bad Config row fails here, not deep inside a pass).
    IF @MediumRowCountThreshold < 0 OR @LargeRowCountThreshold < 0
    BEGIN
        RAISERROR('Row count thresholds must be non-negative.', 16, 1);
        RETURN;
    END;

    IF @LargeRowCountThreshold < @MediumRowCountThreshold
    BEGIN
        RAISERROR('@LargeRowCountThreshold (%I64d) must be >= @MediumRowCountThreshold (%I64d).', 16, 1, @LargeRowCountThreshold, @MediumRowCountThreshold);
        RETURN;
    END;

    -- 100 = FULLSCAN is the top of the range; 0 is not a legal sample.
    IF @SmallTableSamplePercent NOT BETWEEN 1 AND 100
        OR @MediumTableSamplePercent NOT BETWEEN 1 AND 100
        OR @LargeTableSamplePercent NOT BETWEEN 1 AND 100
    BEGIN
        RAISERROR('Sample percent parameters must be between 1 and 100 (100 = FULLSCAN).', 16, 1);
        RETURN;
    END;

    -- Mirror Ola's own validation so we reject a bad value here rather than deep inside IndexOptimize.
    IF @StatisticsModificationLevel IS NOT NULL AND @StatisticsModificationLevel NOT BETWEEN 1 AND 100
    BEGIN
        RAISERROR('@StatisticsModificationLevel must be between 1 and 100, or NULL.', 16, 1);
        RETURN;
    END;

    -- Which size buckets to process this run. NULL/empty = all three (the normal case). Naming a
    -- subset lets a schedule run, say, Large tables on their own (less frequent) cadence separate
    -- from the small/medium tables. Parsed case-insensitively; unknown tokens are rejected.
    -- UNIQUE (not PK) so the column stays nullable: an unrecognized token maps to a single NULL
    -- sentinel we detect below. SQL Server allows exactly one NULL under UNIQUE, and the DISTINCT
    -- insert collapses multiple bad tokens to that one NULL, so the constraint always holds.
    DECLARE @SelectedBuckets TABLE (Bucket varchar(6) NULL UNIQUE);

    IF @Buckets IS NULL OR LEN(LTRIM(RTRIM(@Buckets))) = 0
    BEGIN
        INSERT INTO @SelectedBuckets (Bucket) VALUES ('Small'), ('Medium'), ('Large');
    END;
    ELSE
    BEGIN
        -- Map each token to its canonical bucket name; an unrecognized token maps to NULL so we can
        -- detect and reject it below (the table allows NULL precisely so the bad value lands here
        -- rather than erroring on insert).
        INSERT INTO @SelectedBuckets (Bucket)
        SELECT DISTINCT
            CASE LOWER(LTRIM(RTRIM(value)))
                WHEN 'small'  THEN 'Small'
                WHEN 'medium' THEN 'Medium'
                WHEN 'large'  THEN 'Large'
            END
        FROM STRING_SPLIT(@Buckets, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

        -- Any token that didn't map to a real bucket is a typo -> fail loudly.
        IF EXISTS (SELECT 1 FROM @SelectedBuckets WHERE Bucket IS NULL)
        BEGIN
            RAISERROR('@Buckets may only contain Small, Medium, and/or Large (comma-separated).', 16, 1);
            RETURN;
        END;
    END;

    -- A histogram's max step is always >= its average step, so the ratio is always >= 1.
    -- A cutoff at/below 1 would flag every table; reject it rather than do useless work.
    IF @SkewAnalysis = 1 AND @SkewRatioCutoff <= 1
    BEGIN
        RAISERROR('@SkewRatioCutoff must be > 1 (the max/avg step ratio is always >= 1).', 16, 1);
        RETURN;
    END;

    -------------------------------------------------------------------------------------------
    -- Shred the per-table override JSON (the 'STATOVERRIDE' Config row) for THIS database into a
    -- temp table. The row holds overrides for every database, so we filter to @DbName. Absent row
    -- (or no dbo.Config) -> @overrideJson is NULL -> the block is skipped and behavior is identical
    -- to a plain size-driven run. An override naming a table with no statistics simply never
    -- matches the worklist and is ignored.
    -------------------------------------------------------------------------------------------
    DECLARE @overrideJson nvarchar(max) = (SELECT UnicodeValue FROM @cfg WHERE ConfigCode = 'STATOVERRIDE');

    CREATE TABLE #Overrides (
        SchemaName sysname     NOT NULL,
        ObjectName sysname     NOT NULL,
        OvExclude  bit         NULL,
        OvSample   tinyint     NULL,
        OvBucket   varchar(6)  NULL,
        OvLock     bit         NULL         -- tri-state: 1 = force lock, 0 = force-exempt, NULL = use threshold
    );

    IF @overrideJson IS NOT NULL
    BEGIN
        INSERT INTO #Overrides (SchemaName, ObjectName, OvExclude, OvSample, OvBucket, OvLock)
        SELECT j.[schema], j.[table], j.[exclude], j.[sample], j.[bucket], j.[lock]
        FROM OPENJSON(@overrideJson)
            WITH (
                db       sysname    N'$.db',
                [schema] sysname    N'$.schema',
                [table]  sysname    N'$.table',
                [exclude] bit       N'$.exclude',
                [sample]  tinyint   N'$.sample',
                [bucket]  varchar(6) N'$.bucket',
                [lock]    bit        N'$.lock'
            ) AS j
        WHERE j.db = @DbName;

        -- Fail loudly on a bad override value rather than silently mis-sampling.
        IF EXISTS (SELECT 1 FROM #Overrides WHERE OvSample IS NOT NULL AND OvSample NOT BETWEEN 1 AND 100)
        BEGIN
            RAISERROR('An override sample percent must be between 1 and 100 (100 = FULLSCAN).', 16, 1);
            RETURN;
        END;

        IF EXISTS (SELECT 1 FROM #Overrides WHERE OvBucket IS NOT NULL AND OvBucket NOT IN ('Small', 'Medium', 'Large'))
        BEGIN
            RAISERROR('An override bucket must be Small, Medium, or Large.', 16, 1);
            RETURN;
        END;
    END;

    -------------------------------------------------------------------------------------------
    -- Build the worklist: one row per user table that has at least one statistic, with its
    -- allocated row count and whether any of its stats are still auto-updating. This is the only
    -- read we do up front, and it is deliberately cheap -- metadata and partition-stats row
    -- counts only, no histogram reads and no per-stat dm_db_stats_properties.
    -------------------------------------------------------------------------------------------
    CREATE TABLE #Worklist (
        SchemaName        sysname,
        ObjectName        sysname,
        RowCount_Alloc    bigint       NOT NULL,
        HasUnlockedStat   bit          NOT NULL,    -- at least one stat with no_recompute = 0
        HasLockedStat     bit          NOT NULL,    -- at least one stat with no_recompute = 1 (already locked)
        IsMemoryOptimized bit          NOT NULL,
        Bucket            varchar(6)   NULL,        -- Small / Medium / Large (after override + skew bump)
        IsSkewed          bit          NOT NULL DEFAULT (0),  -- bumped down a bucket this run
        IsLockCandidate   bit          NOT NULL DEFAULT (0),
        IsNewlyLocked     bit          NOT NULL DEFAULT (0),
        OvExclude         bit          NULL,        -- per-table override: skip entirely
        OvSample          tinyint      NULL,        -- per-table override: forced sample percent
        OvBucket          varchar(6)   NULL,        -- per-table override: forced bucket
        OvLock            bit          NULL,        -- per-table override: 1 force lock, 0 force-exempt
        EffectiveSample   tinyint      NULL         -- resolved sample: override, else bucket sample
    );

    DECLARE @analyzeSql nvarchar(max),
            @dbExec      nvarchar(300);

    -- Stats and partition DMVs are database-scoped, so the analysis must run in @DbName's context.
    SET @dbExec = QUOTENAME(@DbName) + N'.sys.sp_executesql';

    SET @analyzeSql = N'
    WITH TableRows AS (
        SELECT
            ps.object_id,
            RowCount_Alloc = SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END)
        FROM sys.dm_db_partition_stats AS ps
        GROUP BY ps.object_id
    )
    SELECT
        SchemaName        = sch.name,
        ObjectName        = o.name,
        RowCount_Alloc    = ISNULL(tr.RowCount_Alloc, 0),
        HasUnlockedStat   = MAX(CASE WHEN st.no_recompute = 0 THEN 1 ELSE 0 END),
        HasLockedStat     = MAX(CASE WHEN st.no_recompute = 1 THEN 1 ELSE 0 END),
        IsMemoryOptimized = ISNULL(MAX(CONVERT(int, t.is_memory_optimized)), 0)
    FROM sys.objects AS o
    JOIN sys.schemas AS sch
        ON sch.schema_id = o.schema_id
    JOIN sys.stats AS st
        ON st.object_id = o.object_id
    LEFT JOIN sys.tables AS t
        ON t.object_id = o.object_id
    LEFT JOIN TableRows AS tr
        ON tr.object_id = o.object_id
    WHERE o.is_ms_shipped = 0
      AND o.type = ''U''
    GROUP BY sch.name, o.name, tr.RowCount_Alloc;';

    INSERT INTO #Worklist (SchemaName, ObjectName, RowCount_Alloc, HasUnlockedStat, HasLockedStat, IsMemoryOptimized)
    EXEC @dbExec @stmt = @analyzeSql;

    IF NOT EXISTS (SELECT 1 FROM #Worklist)
    BEGIN
        IF @Debug = 1
            EXEC dbo.Debug_Print @DebugMessage = N'No user tables with statistics found in the target database. Nothing to do.';
        RETURN;
    END;

    -- Attach any per-table overrides to the worklist rows they match. ObjectName is matched with
    -- LIKE, so an override table of '%old' skips every table whose name ends in "old" (the same
    -- wildcard shape the old hand-built Ola exclusion token used). SchemaName stays an exact match.
    -- Because _ and [ are LIKE metacharacters, a literal table name containing them could also
    -- match siblings; to keep that safe we rank an EXACT (=) name match above a wildcard (LIKE-only)
    -- match, per attribute:
    --   * Exclude is a veto: ANY matching row (exact or wildcard) that says exclude wins.
    --   * Sample / bucket: an exact-name override wins; otherwise a wildcard override supplies it.
    --     If ONLY wildcards match and they disagree, that's ambiguous config -> raise rather than
    --     silently pick one.
    IF @overrideJson IS NOT NULL
    BEGIN
        -- Guard: ambiguous wildcard-only sample (2+ distinct values, no exact match to break the tie).
        IF EXISTS (
            SELECT 1
            FROM #Worklist AS wl
            JOIN #Overrides AS o
                ON o.SchemaName = wl.SchemaName
                AND wl.ObjectName LIKE o.ObjectName
            WHERE o.OvSample IS NOT NULL
            GROUP BY wl.SchemaName, wl.ObjectName
            HAVING COUNT(DISTINCT o.OvSample) > 1
               AND MAX(CASE WHEN o.ObjectName = wl.ObjectName THEN 1 ELSE 0 END) = 0
        )
        BEGIN
            RAISERROR('Conflicting wildcard sample overrides match the same table with no exact-name override to resolve it.', 16, 1);
            RETURN;
        END;

        -- Guard: same ambiguity for bucket.
        IF EXISTS (
            SELECT 1
            FROM #Worklist AS wl
            JOIN #Overrides AS o
                ON o.SchemaName = wl.SchemaName
                AND wl.ObjectName LIKE o.ObjectName
            WHERE o.OvBucket IS NOT NULL
            GROUP BY wl.SchemaName, wl.ObjectName
            HAVING COUNT(DISTINCT o.OvBucket) > 1
               AND MAX(CASE WHEN o.ObjectName = wl.ObjectName THEN 1 ELSE 0 END) = 0
        )
        BEGIN
            RAISERROR('Conflicting wildcard bucket overrides match the same table with no exact-name override to resolve it.', 16, 1);
            RETURN;
        END;

        -- Guard: same ambiguity for lock (tri-state, so distinct 0 vs 1 collide).
        IF EXISTS (
            SELECT 1
            FROM #Worklist AS wl
            JOIN #Overrides AS o
                ON o.SchemaName = wl.SchemaName
                AND wl.ObjectName LIKE o.ObjectName
            WHERE o.OvLock IS NOT NULL
            GROUP BY wl.SchemaName, wl.ObjectName
            HAVING COUNT(DISTINCT o.OvLock) > 1
               AND MAX(CASE WHEN o.ObjectName = wl.ObjectName THEN 1 ELSE 0 END) = 0
        )
        BEGIN
            RAISERROR('Conflicting wildcard lock overrides match the same table with no exact-name override to resolve it.', 16, 1);
            RETURN;
        END;

        -- Exclude: any matching override (exact or wildcard) that says exclude wins.
        UPDATE wl
        SET wl.OvExclude = 1
        FROM #Worklist AS wl
        WHERE EXISTS (
            SELECT 1 FROM #Overrides AS o
            WHERE o.SchemaName = wl.SchemaName
              AND wl.ObjectName LIKE o.ObjectName
              AND o.OvExclude = 1
        );

        -- Sample: prefer an exact-name override, else the (unambiguous) wildcard one.
        UPDATE wl
        SET wl.OvSample = x.OvSample
        FROM #Worklist AS wl
        CROSS APPLY (
            SELECT TOP (1) o.OvSample
            FROM #Overrides AS o
            WHERE o.SchemaName = wl.SchemaName
              AND wl.ObjectName LIKE o.ObjectName
              AND o.OvSample IS NOT NULL
            ORDER BY CASE WHEN o.ObjectName = wl.ObjectName THEN 0 ELSE 1 END
        ) AS x;

        -- Bucket: same exact-beats-wildcard resolution.
        UPDATE wl
        SET wl.OvBucket = x.OvBucket
        FROM #Worklist AS wl
        CROSS APPLY (
            SELECT TOP (1) o.OvBucket
            FROM #Overrides AS o
            WHERE o.SchemaName = wl.SchemaName
              AND wl.ObjectName LIKE o.ObjectName
              AND o.OvBucket IS NOT NULL
            ORDER BY CASE WHEN o.ObjectName = wl.ObjectName THEN 0 ELSE 1 END
        ) AS x;

        -- Lock: same exact-beats-wildcard resolution. Tri-state, so 0 (force-exempt) is a real
        -- value we must keep -- filter on IS NOT NULL, not on truthiness.
        UPDATE wl
        SET wl.OvLock = x.OvLock
        FROM #Worklist AS wl
        CROSS APPLY (
            SELECT TOP (1) o.OvLock
            FROM #Overrides AS o
            WHERE o.SchemaName = wl.SchemaName
              AND wl.ObjectName LIKE o.ObjectName
              AND o.OvLock IS NOT NULL
            ORDER BY CASE WHEN o.ObjectName = wl.ObjectName THEN 0 ELSE 1 END
        ) AS x;
    END;

    -- Resolve each table's bucket (an explicit override wins over row count) and whether it's a
    -- lock candidate. Lock candidacy is orthogonal to the sample bucket. A per-table lock override
    -- (OvLock) overrides the size threshold: 1 forces the lock even below @DisableAutoStatsThreshold,
    -- 0 force-exempts it even above; NULL falls back to the threshold rule. Either way, the HARD
    -- preconditions always hold -- we only lock a table that still has an auto-updating stat to
    -- lock, isn't memory-optimized (sp_autostats can't lock those), and isn't excluded from the run
    -- (locking a table we then never refresh would freeze its stats, the exact failure we prevent).
    UPDATE #Worklist
    SET Bucket = COALESCE(
                    OvBucket,
                    CASE
                        WHEN RowCount_Alloc >= @LargeRowCountThreshold  THEN 'Large'
                        WHEN RowCount_Alloc >= @MediumRowCountThreshold THEN 'Medium'
                        ELSE 'Small'
                    END),
        IsLockCandidate = CASE
                            WHEN HasUnlockedStat = 1
                                AND IsMemoryOptimized = 0
                                AND ISNULL(OvExclude, 0) = 0
                                AND (
                                        OvLock = 1                              -- forced on
                                     OR (OvLock IS NULL                         -- else threshold rule
                                         AND @DisableAutoStatsThreshold IS NOT NULL
                                         AND RowCount_Alloc >= @DisableAutoStatsThreshold)
                                    )
                                THEN 1
                            ELSE 0
                          END;

    -------------------------------------------------------------------------------------------
    -- Optional skew analysis. A sampled histogram misrepresents a skewed column much worse than
    -- an evenly-distributed one, so a skewed table deserves a larger sample than its row count
    -- alone earns it. We read histograms (the one expensive read in this proc) ONLY when asked,
    -- and ONLY for Medium/Large tables -- Small tables have no larger-sample bucket to bump into.
    -- A table with an explicit bucket override is left alone: the human's choice wins over skew.
    -- The skew measure is MAX(step rows) / AVG(step rows) across a stat's histogram, the same
    -- ratio dbo.Check_StatsDetails reports; a table is skewed if ANY of its stats clears the cutoff.
    -- The dynamic batch runs in @DbName's context (so the DMVs resolve there) but updates the
    -- session-scoped #Worklist directly, since temp tables are visible across the context switch.
    -------------------------------------------------------------------------------------------
    IF @SkewAnalysis = 1
    BEGIN
        DECLARE @skewSql nvarchar(max);

        SET @skewSql = N'
        UPDATE wl
        SET IsSkewed = 1
        FROM #Worklist AS wl
        JOIN sys.schemas AS sch
            ON sch.name = wl.SchemaName
        JOIN sys.objects AS o
            ON o.schema_id = sch.schema_id
            AND o.name = wl.ObjectName
        WHERE wl.Bucket IN (''Medium'', ''Large'')
          AND wl.OvBucket IS NULL
          AND EXISTS (
              SELECT 1
              FROM sys.stats AS s
              CROSS APPLY (
                  SELECT
                      MaxStepRows = MAX(h.equal_rows + h.range_rows),
                      AvgStepRows = NULLIF(AVG(h.equal_rows + h.range_rows), 0)
                  FROM sys.dm_db_stats_histogram(s.object_id, s.stats_id) AS h
              ) AS sk
              WHERE s.object_id = o.object_id
                AND sk.MaxStepRows / sk.AvgStepRows > @SkewCutoff
          );';

        IF @Debug = 1
            EXEC dbo.Debug_Print @DebugMessage = @skewSql;

        EXEC @dbExec
            @stmt = @skewSql,
            @params = N'@SkewCutoff decimal(10,2)',
            @SkewCutoff = @SkewRatioCutoff;

        -- Bump every skewed table down exactly one bucket so it rides the next-larger sample
        -- percent (Large -> Medium, Medium -> Small). Recomputed from row count every run, so it
        -- never compounds: a Large table is always re-derived as Large first, then bumped once.
        UPDATE #Worklist
        SET Bucket = CASE Bucket
                        WHEN 'Large'  THEN 'Medium'
                        WHEN 'Medium' THEN 'Small'
                        ELSE Bucket
                     END
        WHERE IsSkewed = 1;
    END;

    -- Everything we lock this run is "newly locked" -> it goes through the forced pass below.
    UPDATE #Worklist
    SET IsNewlyLocked = IsLockCandidate;

    -- Resolve the effective sample per table: an explicit per-table override wins, otherwise the
    -- table rides its (post-override, post-skew) bucket's sample percent.
    UPDATE #Worklist
    SET EffectiveSample = COALESCE(
                            OvSample,
                            CASE Bucket
                                WHEN 'Large'  THEN @LargeTableSamplePercent
                                WHEN 'Medium' THEN @MediumTableSamplePercent
                                ELSE @SmallTableSamplePercent
                            END);

    IF @Debug = 1
    BEGIN
        SELECT
            SchemaName, ObjectName, RowCount_Alloc, Bucket, EffectiveSample,
            IsSkewed, HasUnlockedStat, HasLockedStat, IsMemoryOptimized, IsLockCandidate, IsNewlyLocked,
            OvExclude, OvSample, OvBucket, OvLock
        FROM #Worklist
        ORDER BY RowCount_Alloc DESC;
    END;

    -------------------------------------------------------------------------------------------
    -- Step 1: lock auto-stats on the newly-locked tables (sys.sp_autostats @flagc = 'OFF').
    -- Pure metadata flip -- no UPDATE STATISTICS -- so this is instant even on billion-row tables;
    -- Ola does the actual refresh in the forced pass. sp_autostats is database-scoped, so we call
    -- the database-qualified system proc. With no @indname it covers index AND column stats.
    -------------------------------------------------------------------------------------------
    DECLARE @autoStatsProc nvarchar(300) = QUOTENAME(@DbName) + N'.sys.sp_autostats',
            @tableArg       nvarchar(776),
            @debugAutoStats nvarchar(max) = N'';

    DECLARE lock_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT QUOTENAME(SchemaName) + N'.' + QUOTENAME(ObjectName)
        FROM #Worklist
        WHERE IsNewlyLocked = 1
        ORDER BY RowCount_Alloc DESC;

    OPEN lock_cursor;
    FETCH NEXT FROM lock_cursor INTO @tableArg;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @Debug = 1
            SET @debugAutoStats += N'EXEC ' + @autoStatsProc + N' N''' + @tableArg + N''', ''OFF'';' + NCHAR(13) + NCHAR(10);
        ELSE
            EXEC @autoStatsProc @tableArg, 'OFF';   -- positional (@tblname, @flagc), per the documented form

        FETCH NEXT FROM lock_cursor INTO @tableArg;
    END;

    CLOSE lock_cursor;
    DEALLOCATE lock_cursor;

    IF @Debug = 1 AND LEN(@debugAutoStats) > 0
        EXEC dbo.Debug_Print @DebugMessage = @debugAutoStats;

    -------------------------------------------------------------------------------------------
    -- Step 1b: UN-lock auto-stats (sys.sp_autostats @flagc = 'ON') on excluded tables that we
    -- previously locked. This closes a state-change trap: a table locked on an earlier run and
    -- later changed to exclude:true would otherwise keep no_recompute = 1 (auto-stats OFF) while
    -- ALSO being dropped from every refresh pass -- i.e. silently frozen stats, the exact failure
    -- this framework exists to prevent. Excluding a table means "I no longer manage it," so we hand
    -- it back to SQL Server's auto-stats. We only touch tables that ACTUALLY have a locked stat
    -- (HasLockedStat = 1), so a normal exclude of an unlocked table does nothing here. The set is
    -- disjoint from the lock set above (that requires OvExclude = 0), so ordering is irrelevant.
    -- Like the lock step, @Debug prints the calls instead of running them.
    -------------------------------------------------------------------------------------------
    DECLARE @debugUnlock nvarchar(max) = N'';

    DECLARE unlock_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT QUOTENAME(SchemaName) + N'.' + QUOTENAME(ObjectName)
        FROM #Worklist
        WHERE ISNULL(OvExclude, 0) = 1
          AND HasLockedStat = 1
          AND IsMemoryOptimized = 0
        ORDER BY RowCount_Alloc DESC;

    OPEN unlock_cursor;
    FETCH NEXT FROM unlock_cursor INTO @tableArg;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @Debug = 1
            SET @debugUnlock += N'EXEC ' + @autoStatsProc + N' N''' + @tableArg + N''', ''ON'';' + NCHAR(13) + NCHAR(10);
        ELSE
            EXEC @autoStatsProc @tableArg, 'ON';    -- positional (@tblname, @flagc); hand it back to auto-stats

        FETCH NEXT FROM unlock_cursor INTO @tableArg;
    END;

    CLOSE unlock_cursor;
    DEALLOCATE unlock_cursor;

    IF @Debug = 1 AND LEN(@debugUnlock) > 0
        EXEC dbo.Debug_Print @DebugMessage = @debugUnlock;

    -------------------------------------------------------------------------------------------
    -- Step 2: assemble the IndexOptimize passes. @Indexes tokens are built with QUOTENAME on each
    -- name part so Ola's PARSENAME split survives dots/special characters; ".%" selects every
    -- index AND column statistic on the table (Ola matches the 4th token against
    -- COALESCE(IndexName, StatisticsName)). CONVERT(nvarchar(max), ...) inside STRING_AGG keeps
    -- the result from being capped at the nvarchar(4000)/8000-byte limit for big lists.
    --
    -- Sample percent used to be a property of the bucket; per-table sample overrides break that,
    -- so we now group by EFFECTIVE SAMPLE. Each explicit-include pass is one (newly-locked?, sample)
    -- group. Newly-locked tables are FORCED (@OnlyModifiedStatistics='N', level NULL) -- the only
    -- Ola combo that updates a counter-0 stat, so a just-locked table gets a real baseline instead
    -- of being skipped. Everyone else is NORMAL ('Y', or 'N'+level when a modification level is set,
    -- because Ola rejects 'Y'+level).
    --
    -- A table is SWEPT by the single ALL_INDEXES pass (so we never enumerate the thousands of small
    -- tables) only when it rides the default Small sample: Small bucket, not newly locked, not
    -- excluded, and no sample override. Everything else -- Medium/Large, newly locked, excluded, or
    -- a Small table with its own sample -- is named explicitly (excluded tables only as a "-" token).
    -------------------------------------------------------------------------------------------
    DECLARE @normalOms char(1),
            @normalSml int;

    IF @StatisticsModificationLevel IS NULL
    BEGIN
        SET @normalOms = 'Y';
        SET @normalSml = NULL;
    END;
    ELSE
    BEGIN
        SET @normalOms = 'N';
        SET @normalSml = @StatisticsModificationLevel;
    END;

    DECLARE @Passes TABLE (
        PassId       int IDENTITY(1,1) PRIMARY KEY,
        PassName     varchar(30)   NOT NULL,
        Bucket       varchar(6)    NOT NULL,   -- which size bucket this pass serves (for @Buckets filtering)
        IsForced     bit           NOT NULL,   -- 1 = newly-locked baseline pass; always runs regardless of @Buckets
        Indexes      nvarchar(max) NOT NULL,
        SamplePercent tinyint      NOT NULL,
        OnlyModified char(1)       NOT NULL,
        ModLevel     int           NULL
    );

    DECLARE @dbQuoted nvarchar(258) = QUOTENAME(@DbName),
            @idx      nvarchar(max);

    --- Explicit-include passes: one per (IsNewlyLocked, Bucket, EffectiveSample) group. Grouping by
    --- Bucket (as well as sample) keeps each pass tied to a single size bucket so @Buckets can filter
    --- it at execution time. A group always has at least one row, so STRING_AGG is never NULL here.
    --- Excluded and swept tables are left out.
    INSERT INTO @Passes (PassName, Bucket, IsForced, Indexes, SamplePercent, OnlyModified, ModLevel)
    SELECT
        PassName = CASE WHEN IsNewlyLocked = 1 THEN 'Forced-' ELSE 'Normal-' END
                    + Bucket + '-' + CONVERT(varchar(10), EffectiveSample),
        Bucket   = Bucket,
        IsForced = IsNewlyLocked,
        Indexes  = STRING_AGG(CONVERT(nvarchar(max), @dbQuoted + N'.' + QUOTENAME(SchemaName) + N'.' + QUOTENAME(ObjectName) + N'.%'), N','),
        SamplePercent = EffectiveSample,
        OnlyModified  = CASE WHEN IsNewlyLocked = 1 THEN 'N' ELSE @normalOms END,
        ModLevel      = CASE WHEN IsNewlyLocked = 1 THEN NULL ELSE @normalSml END
    FROM #Worklist
    WHERE ISNULL(OvExclude, 0) = 0                              -- excluded tables get no include pass
      AND NOT (Bucket = 'Small' AND IsNewlyLocked = 0 AND OvSample IS NULL)  -- these ride ALL_INDEXES
    GROUP BY IsNewlyLocked, Bucket, EffectiveSample;

    --- The ALL_INDEXES Small-Normal pass: everything NOT swept becomes a "-" exclusion, so the sweep
    --- covers exactly the default-sample small tables. Emit only if at least one such table exists.
    --- This pass serves the Small bucket and is not a forced pass.
    IF EXISTS (
        SELECT 1 FROM #Worklist
        WHERE Bucket = 'Small' AND IsNewlyLocked = 0 AND ISNULL(OvExclude, 0) = 0 AND OvSample IS NULL
    )
    BEGIN
        SELECT @idx = N'ALL_INDEXES' +
            ISNULL(N',' + STRING_AGG(CONVERT(nvarchar(max), N'-' + @dbQuoted + N'.' + QUOTENAME(SchemaName) + N'.' + QUOTENAME(ObjectName) + N'.%'), N','), N'')
        FROM #Worklist
        WHERE Bucket IN ('Medium', 'Large')
           OR IsNewlyLocked = 1
           OR ISNULL(OvExclude, 0) = 1
           OR OvSample IS NOT NULL;

        INSERT INTO @Passes (PassName, Bucket, IsForced, Indexes, SamplePercent, OnlyModified, ModLevel)
        VALUES ('Small-Normal', 'Small', 0, @idx, @SmallTableSamplePercent, @normalOms, @normalSml);
    END;

    -------------------------------------------------------------------------------------------
    -- Step 3: run the passes. Each is a single call to STOCK IndexOptimize with all three
    -- fragmentation tiers NULL (statistics-only run -- no reorg/rebuild) and @UpdateStatistics='ALL'.
    -------------------------------------------------------------------------------------------
    DECLARE @logToTableYN char(1) = CASE WHEN @LogToTable = 1 THEN 'Y' ELSE 'N' END;

    DECLARE @passId       int,
            @passName     varchar(30),
            @passBucket   varchar(6),
            @passForced   bit,
            @passIndexes  nvarchar(max),
            @passSample   tinyint,
            @passOms      char(1),
            @passSml      int,
            @msg          nvarchar(max);

    DECLARE @i int = 1,
            @maxPass int = (SELECT ISNULL(MAX(PassId), 0) FROM @Passes);

    IF @Debug = 1 AND @maxPass = 0
        EXEC dbo.Debug_Print @DebugMessage = N'No statistics passes to run for the given parameters.';

    WHILE @i <= @maxPass
    BEGIN
        SELECT
            @passName    = PassName,
            @passBucket  = Bucket,
            @passForced  = IsForced,
            @passIndexes = Indexes,
            @passSample  = SamplePercent,
            @passOms     = OnlyModified,
            @passSml     = ModLevel
        FROM @Passes
        WHERE PassId = @i;

        -- @Buckets filter: run a pass only if its bucket is selected this run, OR it is a forced
        -- (newly-locked) baseline pass. Forced passes ALWAYS run regardless of @Buckets -- a table we
        -- just locked this run must get its baseline refresh or it would be left frozen; skipping it
        -- for being "out of bucket scope" would reintroduce exactly the failure this framework prevents.
        IF @passForced = 0 AND NOT EXISTS (SELECT 1 FROM @SelectedBuckets WHERE Bucket = @passBucket)
        BEGIN
            IF @Debug = 1
            BEGIN
                SET @msg = N'-- Pass: ' + @passName + N'  (SKIPPED: bucket ' + @passBucket + N' not in @Buckets)';
                EXEC dbo.Debug_Print @DebugMessage = @msg;
            END;
            SET @i += 1;
            CONTINUE;
        END;

        IF @Debug = 1
        BEGIN
            SET @msg = N'-- Pass: ' + @passName + NCHAR(13) + NCHAR(10)
                + N'EXEC dbo.IndexOptimize' + NCHAR(13) + NCHAR(10)
                + N'    @Databases = ' + QUOTENAME(@DbName, N'''') + N',' + NCHAR(13) + NCHAR(10)
                + N'    @Indexes = N''' + REPLACE(@passIndexes, N'''', N'''''') + N''',' + NCHAR(13) + NCHAR(10)
                + N'    @FragmentationLow = NULL, @FragmentationMedium = NULL, @FragmentationHigh = NULL,' + NCHAR(13) + NCHAR(10)
                + N'    @UpdateStatistics = ''ALL'',' + NCHAR(13) + NCHAR(10)
                + N'    @StatisticsSample = ' + CONVERT(nvarchar(10), @passSample) + N',' + NCHAR(13) + NCHAR(10)
                + N'    @OnlyModifiedStatistics = ''' + @passOms + N''',' + NCHAR(13) + NCHAR(10)
                + N'    @StatisticsModificationLevel = ' + ISNULL(CONVERT(nvarchar(10), @passSml), N'NULL') + N',' + NCHAR(13) + NCHAR(10)
                + N'    @LogToTable = ''' + @logToTableYN + N''';';
            EXEC dbo.Debug_Print @DebugMessage = @msg;
        END;
        ELSE
        BEGIN
            EXEC dbo.IndexOptimize
                @Databases                   = @DbName,
                @Indexes                     = @passIndexes,
                @FragmentationLow            = NULL,
                @FragmentationMedium         = NULL,
                @FragmentationHigh           = NULL,
                @UpdateStatistics            = 'ALL',
                @StatisticsSample            = @passSample,
                @OnlyModifiedStatistics      = @passOms,
                @StatisticsModificationLevel = @passSml,
                @LogToTable                  = @logToTableYN;
        END;

        SET @i += 1;
    END;
END;
GO
