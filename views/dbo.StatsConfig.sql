CREATE OR ALTER VIEW dbo.StatsConfig
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260713
    Readable view of the statistics-maintenance configuration that dbo.Update_Statistics consumes,
    so the config can be eyeballed as data instead of decoded from raw dbo.Config rows.

    Returns ONE row per per-table override (shredded from the 'STATOVERRIDE' JSON row), plus a
    single summary row (SettingScope = 'ServerDefault', all override columns NULL) carrying the
    per-server default knobs pivoted out of the 'StatisticsMaint' category. A field left NULL on an
    override row means "no opinion -- the table uses the computed default" for that knob.

    This shows STATED intent. The fully rowcount-resolved picture (which bucket each table actually
    lands in, after skew) comes from EXEC dbo.Update_Statistics @Debug = 1.
**************************************************************************************************
MODIFICATIONS:
    20260713 - AM2 - Initial version.
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
WITH Defaults AS (
    SELECT
        MediumRowCountThreshold      = MAX(CASE WHEN ConfigCode = 'STATMEDROWS' THEN NumericValue END),
        LargeRowCountThreshold       = MAX(CASE WHEN ConfigCode = 'STATLRGROWS' THEN NumericValue END),
        SmallTableSamplePercent      = MAX(CASE WHEN ConfigCode = 'STATSMPSML'  THEN NumericValue END),
        MediumTableSamplePercent     = MAX(CASE WHEN ConfigCode = 'STATSMPMED'  THEN NumericValue END),
        LargeTableSamplePercent      = MAX(CASE WHEN ConfigCode = 'STATSMPLRG'  THEN NumericValue END),
        SkewAnalysis                 = MAX(CASE WHEN ConfigCode = 'STATSKEW'    THEN NumericValue END),
        SkewRatioCutoff              = MAX(CASE WHEN ConfigCode = 'STATSKEWCUT' THEN NumericValue END),
        DisableAutoStatsThreshold    = MAX(CASE WHEN ConfigCode = 'STATLOCKROW' THEN NumericValue END),
        StatisticsModificationLevel  = MAX(CASE WHEN ConfigCode = 'STATMODLVL'  THEN NumericValue END),
        LogToTable                   = MAX(CASE WHEN ConfigCode = 'STATLOGTBL'  THEN NumericValue END),
        OverrideJson                 = MAX(CASE WHEN ConfigCode = 'STATOVERRIDE' THEN UnicodeValue END)
    FROM dbo.Config
    WHERE ConfigCategory = 'StatisticsMaint'
)
-- The per-server default knobs, as a single summary row.
SELECT
    SettingScope                 = CONVERT(varchar(13), 'ServerDefault'),
    DatabaseName                 = CONVERT(sysname, NULL),
    SchemaName                   = CONVERT(sysname, NULL),
    ObjectName                   = CONVERT(sysname, NULL),
    OverrideExclude              = CONVERT(bit, NULL),
    OverrideSamplePercent        = CONVERT(tinyint, NULL),
    OverrideBucket               = CONVERT(varchar(6), NULL),
    OverrideLock                 = CONVERT(bit, NULL),
    d.MediumRowCountThreshold,
    d.LargeRowCountThreshold,
    d.SmallTableSamplePercent,
    d.MediumTableSamplePercent,
    d.LargeTableSamplePercent,
    d.SkewAnalysis,
    d.SkewRatioCutoff,
    d.DisableAutoStatsThreshold,
    d.StatisticsModificationLevel,
    d.LogToTable
FROM Defaults AS d
UNION ALL
-- One row per per-table override, with the server defaults repeated for at-a-glance context.
SELECT
    SettingScope                 = CONVERT(varchar(13), 'TableOverride'),
    DatabaseName                 = j.db,
    SchemaName                   = j.[schema],
    ObjectName                   = j.[table],
    OverrideExclude              = j.[exclude],
    OverrideSamplePercent        = j.[sample],
    OverrideBucket               = j.[bucket],
    OverrideLock                 = j.[lock],
    d.MediumRowCountThreshold,
    d.LargeRowCountThreshold,
    d.SmallTableSamplePercent,
    d.MediumTableSamplePercent,
    d.LargeTableSamplePercent,
    d.SkewAnalysis,
    d.SkewRatioCutoff,
    d.DisableAutoStatsThreshold,
    d.StatisticsModificationLevel,
    d.LogToTable
FROM Defaults AS d
CROSS APPLY OPENJSON(d.OverrideJson)
    WITH (
        db       sysname     N'$.db',
        [schema] sysname     N'$.schema',
        [table]  sysname     N'$.table',
        [exclude] bit        N'$.exclude',
        [sample]  tinyint    N'$.sample',
        [bucket]  varchar(6) N'$.bucket',
        [lock]    bit        N'$.lock'
    ) AS j;
GO
