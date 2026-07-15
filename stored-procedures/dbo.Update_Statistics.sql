CREATE OR ALTER PROCEDURE dbo.Update_Statistics
    @DbList                     nvarchar(max),           -- Ola-style @Databases list (see header)
    @MediumRowCountThreshold    bigint   = NULL,          -- rows >= this -> Medium bucket
    @LargeRowCountThreshold     bigint   = NULL,          -- rows >= this -> Large bucket
    @SmallTableSamplePercent    tinyint  = NULL,          -- Small bucket sample (100 = FULLSCAN)
    @MediumTableSamplePercent   tinyint  = NULL,          -- Medium bucket sample (100 = FULLSCAN)
    @LargeTableSamplePercent    tinyint  = NULL,          -- Large bucket sample
    @SkewAnalysis               bit      = NULL,          -- 1 = bump skewed Medium/Large tables down a bucket
    @SkewRatioCutoff            decimal(10,2) = NULL,     -- max/avg histogram step ratio considered skewed
    @DisableAutoStatsThreshold  bigint   = NULL,          -- rows >= this -> sp_autostats OFF; NULL = never lock
    @StatisticsModificationLevel int     = NULL,          -- passthrough to the normal pass; NULL = update if modified
    @LogToTable                 bit      = NULL,          -- log Ola commands to dbo.CommandLog
    @Debug                      bit      = 0              -- 1 = print everything we'd run, change nothing
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260715
    Multi-database front door for the statistics driver. This is a thin wrapper over
    dbo.Update_StatisticsSingleDB: it resolves an Ola-Hallengren-style database list into the set
    of databases to act on, then calls the single-database proc once per database. Every parameter
    except @DbList is passed straight through unchanged -- the single-DB proc still owns all the
    real work (config resolution from dbo.Config, bucketing, locking, overrides, the IndexOptimize
    calls). Keeping the loop out here means the single-DB proc stays simple and easy to reason about
    and test, exactly one database at a time.

    @DbList uses the SAME grammar as Ola IndexOptimize's @Databases parameter, and the selection
    logic below is borrowed directly from IndexOptimize so behavior matches what people already know:
      * Keywords: SYSTEM_DATABASES, USER_DATABASES, ALL_DATABASES, AVAILABILITY_GROUP_DATABASES.
      * '-' prefix excludes (e.g. -MyDb, -AVAILABILITY_GROUP_DATABASES).
      * '%' is a wildcard (e.g. %Reporting%).
      * Combine with commas: 'USER_DATABASES, -AVAILABILITY_GROUP_DATABASES, -%_old'.

    ACCESSIBILITY FILTER. Only databases that are safe to touch are looped: state ONLINE, not
    READ_ONLY, not SINGLE_USER, and -- for an AG database -- only when the local replica is PRIMARY.
    tempdb and database snapshots are never included. A selected-but-inaccessible database is
    skipped with a printed note rather than erroring the whole run.

    ERROR ISOLATION. Each database is run inside its own TRY/CATCH. If one database fails, the error
    is captured and the loop continues to the rest; after the loop, a summary error is raised listing
    every database that failed. One bad database never blocks maintenance on the others.

PARAMETERS
* @DbList - Databases to process, in Ola @Databases grammar (see above). Required.
* All other parameters are identical to dbo.Update_StatisticsSingleDB and are passed through
  verbatim; NULL means "let the single-DB proc resolve it from dbo.Config." See that proc's header
  for the full description of each knob and the per-table override behavior.
* @Debug - 1 prints the resolved database list and then calls each database with @Debug = 1 (so
           every sp_autostats and IndexOptimize call is printed), changing nothing.

EXAMPLES:
-- All user databases (the normal fleet call -- the Agent job step is just this):
-- EXEC dbo.Update_Statistics @DbList = N'USER_DATABASES';

-- Dry run across all user DBs that are not in an availability group:
-- EXEC dbo.Update_Statistics @DbList = N'USER_DATABASES, -AVAILABILITY_GROUP_DATABASES', @Debug = 1;

-- A couple of named databases with a one-off giant-sample override:
-- EXEC dbo.Update_Statistics @DbList = N'MyDb, Reporting', @LargeTableSamplePercent = 50;

-- Everything except the staging copies:
-- EXEC dbo.Update_Statistics @DbList = N'USER_DATABASES, -%_staging';

**************************************************************************************************
MODIFICATIONS:
    20260715 - AM2 - Initial version. Multi-database wrapper over dbo.Update_StatisticsSingleDB;
                     borrows Ola IndexOptimize's @Databases selection grammar.
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
BEGIN
    SET NOCOUNT ON;

    DECLARE @StringDelimiter char(1) = N',',
            @Version         int;
    -- Major version number (e.g. 15 for SQL 2019); gates the availability-group lookups below.
    SET @Version = CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)),
                             CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128))) - 1) AS int);

    -------------------------------------------------------------------------------------------
    -- Guard clauses.
    -------------------------------------------------------------------------------------------
    IF @DbList IS NULL OR LEN(LTRIM(RTRIM(@DbList))) = 0
    BEGIN
        RAISERROR('You must supply @DbList (Ola @Databases grammar, e.g. USER_DATABASES).', 16, 1);
        RETURN;
    END;

    -- The single-DB engine must exist -- this proc is only a front door for it.
    IF OBJECT_ID(N'dbo.Update_StatisticsSingleDB', N'P') IS NULL
    BEGIN
        RAISERROR('dbo.Update_StatisticsSingleDB was not found. It is required by this wrapper.', 16, 1);
        RETURN;
    END;

    -------------------------------------------------------------------------------------------
    -- Resolve @DbList -> the set of database names, using Ola IndexOptimize's selection logic.
    -- (Parsing CTEs, @SelectedDatabases matching, and availability-group handling are adapted
    -- directly from IndexOptimize so the grammar behaves identically.)
    -------------------------------------------------------------------------------------------
    DECLARE @SelectedDatabases TABLE (
        DatabaseName      nvarchar(max),
        DatabaseType      nvarchar(max),
        AvailabilityGroup nvarchar(max),
        StartPosition     int,
        Selected          bit
    );

    DECLARE @tmpDatabases TABLE (
        ID                int IDENTITY,
        DatabaseName      nvarchar(max),
        DatabaseType      nvarchar(max),
        AvailabilityGroup bit,
        StartPosition     int,
        Selected          bit,
        Completed         bit
    );

    DECLARE @tmpDatabasesAvailabilityGroups TABLE (
        DatabaseName          nvarchar(max),
        AvailabilityGroupName nvarchar(max)
    );

    -- Normalize whitespace around delimiters (as IndexOptimize does).
    SET @DbList = REPLACE(REPLACE(@DbList, CHAR(10), ''), CHAR(13), '');
    WHILE CHARINDEX(@StringDelimiter + ' ', @DbList) > 0 SET @DbList = REPLACE(@DbList, @StringDelimiter + ' ', @StringDelimiter);
    WHILE CHARINDEX(' ' + @StringDelimiter, @DbList) > 0 SET @DbList = REPLACE(@DbList, ' ' + @StringDelimiter, @StringDelimiter);
    SET @DbList = LTRIM(RTRIM(@DbList));

    WITH Databases1 (StartPosition, EndPosition, DatabaseItem) AS
    (
        SELECT 1 AS StartPosition,
               ISNULL(NULLIF(CHARINDEX(@StringDelimiter, @DbList, 1), 0), LEN(@DbList) + 1) AS EndPosition,
               SUBSTRING(@DbList, 1, ISNULL(NULLIF(CHARINDEX(@StringDelimiter, @DbList, 1), 0), LEN(@DbList) + 1) - 1) AS DatabaseItem
        WHERE @DbList IS NOT NULL
        UNION ALL
        SELECT CAST(EndPosition AS int) + 1 AS StartPosition,
               ISNULL(NULLIF(CHARINDEX(@StringDelimiter, @DbList, EndPosition + 1), 0), LEN(@DbList) + 1) AS EndPosition,
               SUBSTRING(@DbList, EndPosition + 1, ISNULL(NULLIF(CHARINDEX(@StringDelimiter, @DbList, EndPosition + 1), 0), LEN(@DbList) + 1) - EndPosition - 1) AS DatabaseItem
        FROM Databases1
        WHERE EndPosition < LEN(@DbList) + 1
    ),
    Databases2 (DatabaseItem, StartPosition, Selected) AS
    (
        SELECT CASE WHEN DatabaseItem LIKE '-%' THEN RIGHT(DatabaseItem, LEN(DatabaseItem) - 1) ELSE DatabaseItem END AS DatabaseItem,
               StartPosition,
               CASE WHEN DatabaseItem LIKE '-%' THEN 0 ELSE 1 END AS Selected
        FROM Databases1
    ),
    Databases3 (DatabaseItem, DatabaseType, AvailabilityGroup, StartPosition, Selected) AS
    (
        SELECT CASE WHEN DatabaseItem IN ('ALL_DATABASES','SYSTEM_DATABASES','USER_DATABASES','AVAILABILITY_GROUP_DATABASES') THEN '%' ELSE DatabaseItem END AS DatabaseItem,
               CASE WHEN DatabaseItem = 'SYSTEM_DATABASES' THEN 'S' WHEN DatabaseItem = 'USER_DATABASES' THEN 'U' ELSE NULL END AS DatabaseType,
               CASE WHEN DatabaseItem = 'AVAILABILITY_GROUP_DATABASES' THEN 1 ELSE NULL END AS AvailabilityGroup,
               StartPosition,
               Selected
        FROM Databases2
    ),
    Databases4 (DatabaseName, DatabaseType, AvailabilityGroup, StartPosition, Selected) AS
    (
        SELECT CASE WHEN LEFT(DatabaseItem,1) = '[' AND RIGHT(DatabaseItem,1) = ']' THEN PARSENAME(DatabaseItem,1) ELSE DatabaseItem END AS DatabaseName,
               DatabaseType,
               AvailabilityGroup,
               StartPosition,
               Selected
        FROM Databases3
    )
    INSERT INTO @SelectedDatabases (DatabaseName, DatabaseType, AvailabilityGroup, StartPosition, Selected)
    SELECT DatabaseName, DatabaseType, AvailabilityGroup, StartPosition, Selected
    FROM Databases4
    OPTION (MAXRECURSION 0);

    -- Reject a malformed list rather than silently doing nothing.
    IF NOT EXISTS (SELECT 1 FROM @SelectedDatabases)
        OR EXISTS (SELECT 1 FROM @SelectedDatabases WHERE DatabaseName IS NULL OR DATALENGTH(DatabaseName) = 0)
    BEGIN
        RAISERROR('The value for the parameter @DbList is not supported.', 16, 1);
        RETURN;
    END;

    -- Map databases to availability groups (only when HADR is enabled).
    IF @Version >= 11 AND SERVERPROPERTY('IsHadrEnabled') = 1
    BEGIN
        INSERT INTO @tmpDatabasesAvailabilityGroups (DatabaseName, AvailabilityGroupName)
        SELECT databases.name, availability_groups.name
        FROM sys.databases AS databases
        INNER JOIN sys.availability_replicas AS availability_replicas ON databases.replica_id = availability_replicas.replica_id
        INNER JOIN sys.availability_groups AS availability_groups ON availability_replicas.group_id = availability_groups.group_id;
    END;

    -- Candidate databases (tempdb and snapshots excluded, as IndexOptimize does).
    INSERT INTO @tmpDatabases (DatabaseName, DatabaseType, AvailabilityGroup, StartPosition, Selected, Completed)
    SELECT [name] AS DatabaseName,
           CASE WHEN name IN ('master','msdb','model') OR is_distributor = 1 THEN 'S' ELSE 'U' END AS DatabaseType,
           NULL AS AvailabilityGroup,
           0 AS StartPosition,
           0 AS Selected,
           0 AS Completed
    FROM sys.databases
    WHERE [name] <> 'tempdb'
      AND source_database_id IS NULL
    ORDER BY [name] ASC;

    UPDATE tmpDatabases
    SET AvailabilityGroup = CASE WHEN EXISTS (SELECT 1 FROM @tmpDatabasesAvailabilityGroups AS ag WHERE ag.DatabaseName = tmpDatabases.DatabaseName) THEN 1 ELSE 0 END
    FROM @tmpDatabases AS tmpDatabases;

    -- Apply the include selections, then the exclude selections (order matters -- excludes win).
    UPDATE tmpDatabases
    SET tmpDatabases.Selected = SelectedDatabases.Selected
    FROM @tmpDatabases AS tmpDatabases
    INNER JOIN @SelectedDatabases AS SelectedDatabases
        ON tmpDatabases.DatabaseName LIKE REPLACE(SelectedDatabases.DatabaseName, '_', '[_]')
        AND (tmpDatabases.DatabaseType = SelectedDatabases.DatabaseType OR SelectedDatabases.DatabaseType IS NULL)
        AND (tmpDatabases.AvailabilityGroup = SelectedDatabases.AvailabilityGroup OR SelectedDatabases.AvailabilityGroup IS NULL)
    WHERE SelectedDatabases.Selected = 1;

    UPDATE tmpDatabases
    SET tmpDatabases.Selected = SelectedDatabases.Selected
    FROM @tmpDatabases AS tmpDatabases
    INNER JOIN @SelectedDatabases AS SelectedDatabases
        ON tmpDatabases.DatabaseName LIKE REPLACE(SelectedDatabases.DatabaseName, '_', '[_]')
        AND (tmpDatabases.DatabaseType = SelectedDatabases.DatabaseType OR SelectedDatabases.DatabaseType IS NULL)
        AND (tmpDatabases.AvailabilityGroup = SelectedDatabases.AvailabilityGroup OR SelectedDatabases.AvailabilityGroup IS NULL)
    WHERE SelectedDatabases.Selected = 0;

    -------------------------------------------------------------------------------------------
    -- Narrow to the databases that are actually safe to touch, and note why any selected
    -- database was skipped (so a @Debug run explains the gaps). Accessibility mirrors the gate
    -- IndexOptimize applies per database: ONLINE, not READ_ONLY, not SINGLE_USER, and -- for an
    -- AG database -- only when the local replica is PRIMARY.
    -------------------------------------------------------------------------------------------
    DECLARE @Worklist TABLE (
        DatabaseName nvarchar(max) NOT NULL,
        Skipped      bit           NOT NULL,
        SkipReason   nvarchar(200) NULL
    );

    INSERT INTO @Worklist (DatabaseName, Skipped, SkipReason)
    SELECT d.name,
           Skipped = CASE
                        WHEN d.state_desc <> 'ONLINE' THEN 1
                        WHEN d.is_read_only = 1 THEN 1
                        WHEN d.user_access_desc = 'SINGLE_USER' THEN 1
                        WHEN td.AvailabilityGroup = 1 AND ISNULL(ars.role_desc, 'RESOLVING') <> 'PRIMARY' THEN 1
                        ELSE 0
                     END,
           SkipReason = CASE
                        WHEN d.state_desc <> 'ONLINE' THEN 'not ONLINE (' + d.state_desc + ')'
                        WHEN d.is_read_only = 1 THEN 'READ_ONLY'
                        WHEN d.user_access_desc = 'SINGLE_USER' THEN 'SINGLE_USER'
                        WHEN td.AvailabilityGroup = 1 AND ISNULL(ars.role_desc, 'RESOLVING') <> 'PRIMARY' THEN 'AG replica not PRIMARY'
                        ELSE NULL
                     END
    FROM @tmpDatabases AS td
    INNER JOIN sys.databases AS d ON d.name = td.DatabaseName
    LEFT JOIN sys.dm_hadr_availability_replica_states AS ars
        ON ars.replica_id = d.replica_id AND ars.is_local = 1
    WHERE td.Selected = 1;

    IF @Debug = 1
    BEGIN
        DECLARE @dbgList nvarchar(max) = N'Resolved @DbList = ' + @DbList + NCHAR(13) + NCHAR(10);
        SELECT @dbgList += N'  ' + CASE WHEN Skipped = 1 THEN N'SKIP  ' ELSE N'RUN   ' END
                            + DatabaseName
                            + ISNULL(N'  -- ' + SkipReason, N'')
                            + NCHAR(13) + NCHAR(10)
        FROM @Worklist
        ORDER BY DatabaseName;
        EXEC dbo.Debug_Print @DebugMessage = @dbgList;
    END;

    IF NOT EXISTS (SELECT 1 FROM @Worklist WHERE Skipped = 0)
    BEGIN
        IF @Debug = 1
            EXEC dbo.Debug_Print @DebugMessage = N'No accessible databases matched @DbList. Nothing to do.';
        RETURN;
    END;

    -------------------------------------------------------------------------------------------
    -- Loop the accessible databases, calling the single-DB engine for each. Each call is isolated
    -- in its own TRY/CATCH so one failure doesn't stop the rest; failures are collected and raised
    -- as a summary at the end.
    -------------------------------------------------------------------------------------------
    DECLARE @CurrentDbName sysname,
            @failures      nvarchar(max) = N'',
            @failCount     int = 0,
            @errMsg        nvarchar(max);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT DatabaseName FROM @Worklist WHERE Skipped = 0 ORDER BY DatabaseName;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @CurrentDbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @Debug = 1
        BEGIN
            DECLARE @dbHeader nvarchar(max) = N'===== Database: ' + @CurrentDbName + N' =====';
            EXEC dbo.Debug_Print @DebugMessage = @dbHeader;
        END;

        BEGIN TRY
            EXEC dbo.Update_StatisticsSingleDB
                @DbName                      = @CurrentDbName,
                @MediumRowCountThreshold     = @MediumRowCountThreshold,
                @LargeRowCountThreshold      = @LargeRowCountThreshold,
                @SmallTableSamplePercent     = @SmallTableSamplePercent,
                @MediumTableSamplePercent    = @MediumTableSamplePercent,
                @LargeTableSamplePercent     = @LargeTableSamplePercent,
                @SkewAnalysis                = @SkewAnalysis,
                @SkewRatioCutoff             = @SkewRatioCutoff,
                @DisableAutoStatsThreshold   = @DisableAutoStatsThreshold,
                @StatisticsModificationLevel = @StatisticsModificationLevel,
                @LogToTable                  = @LogToTable,
                @Debug                       = @Debug;
        END TRY
        BEGIN CATCH
            SET @failCount += 1;
            SET @errMsg = N'  ' + @CurrentDbName + N': Msg ' + CONVERT(nvarchar(10), ERROR_NUMBER())
                        + N', ' + ISNULL(ERROR_MESSAGE(), N'') + NCHAR(13) + NCHAR(10);
            SET @failures += @errMsg;
            -- Surface it immediately too, so a long run shows problems as they happen.
            RAISERROR('Update_StatisticsSingleDB failed for database %s: %s', 12, 1, @CurrentDbName, @errMsg) WITH NOWAIT;
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @CurrentDbName;
    END;

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    -- If any database failed, raise a summary so the caller/job step registers the failure.
    IF @failCount > 0
    BEGIN
        DECLARE @summary nvarchar(max) =
            CONVERT(nvarchar(10), @failCount) + N' database(s) failed during Update_Statistics:'
            + NCHAR(13) + NCHAR(10) + @failures;
        RAISERROR('%s', 16, 1, @summary);
    END;
END;
GO
