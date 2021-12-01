IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'V' AND object_id = object_id('dbo.DatabaseProperties'))
    EXEC ('CREATE VIEW dbo.DatabaseProperties AS SELECT Result = ''This is a stub'';' )
GO

ALTER VIEW dbo.DatabaseProperties
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 2021130
    EAV-style view to display all database properties, normally accessed via DATABASEPROPERTYEX().
    Includes database properties for all supported versions. If the current server is older or 
    database at a lower compatibility level, and does not support that server property, the 
    PropertyValue will be NULL. See the HelpText for an indication of limited version support.

    Returned columns:
    * DatabaseName - Name of the database.
    * PropertyName - Name of the server property, passed as the argument to the DATABASEPROPERTYEX() function.
    * PropertyValue - Value returned by the DATABASEPROPERTYEX() function.
    * HelpText - Summary of property definition, and version/edition limitations. 

**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/production/LICENSE
    ©2014-2022 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
WITH DbProperties AS (
    SELECT *
    FROM (
        VALUES
            ('Collation',
                N'Default collation name for the database.'),
            ('ComparisonStyle',
                N'The Windows comparison style of the collation; See docs.microsoft.com for details.'),
            ('Edition',
                N'Azure SQLDB; The database edition or service tier.'),
            ('IsAnsiNullDefault',
                N'Database follows ISO rules for allowing null values.'),
            ('IsAnsiNullsEnabled',
                N'All comparisons to a null evaluate to unknown.'),
            ('IsAnsiPaddingEnabled',
                N'Strings are padded to the same length before comparison or insert.'),
            ('IsAnsiWarningsEnabled',
                N'SQL Server issues error or warning messages when standard error conditions occur.'),
            ('IsArithmeticAbortEnabled',
                N'Queries end when an overflow or divide-by-zero error occurs during query execution.'),
            ('IsAutoClose',
                N'This should never be enabled. Database shuts down and frees resources after the last user exits.'),
            ('IsAutoCreateStatistics',
                N'Query optimizer creates single-column statistics, as required, to improve query performance.'),
            ('IsAutoCreateStatisticsIncremental',
                N'2014+; Auto-created single column statistics are incremental when possible.'),
            ('IsAutoShrink',
                N'This should never be enabled. Database files are candidates for automatic periodic shrinking.'),
            ('IsAutoUpdateStatistics',
                N'When a query uses potentially out-of-date existing statistics, the query optimizer updates those statistics.'),
            ('IsClone',
                N'2014 SP2+; Database is a schema- and statistics-only copy of a user database created with DBCC CLONEDATABASE.'),
            ('IsCloseCursorsOnCommitEnabled',
                N'When a transaction commits, all open cursors will close.'),
            ('IsFulltextEnabled',
                N'Database is enabled for full-text and semantic indexing.'),
            ('IsInStandBy',
                N'Database is online as read-only, with restore log allowed.'),
            ('IsLocalCursorsDefault',
                N'Cursor declarations default to LOCAL.'),
            ('IsMemoryOptimizedElevateToSnapshotEnabled',
                N'2014+; Memory-optimized tables are accessed using SNAPSHOT isolation, when the session setting TRANSACTION ISOLATION LEVEL is set to READ COMMITTED, READ UNCOMMITTED, or a lower isolation level.'),
            ('IsMergePublished',
                N'SQL Server supports database table publication for merge replication, if replication is installed.'),
            ('IsNullConcat',
                N'Null concatenation operand yields NULL.'),
            ('IsNumericRoundAbortEnabled',
                N'Errors are generated when a loss of precision occurs in expressions.'),
            ('IsParameterizationForced',
                N'PARAMETERIZATION database SET option is FORCED.'),
            ('IsQuotedIdentifiersEnabled',
                N'Double quotation marks on identifiers are allowed.'),
            ('IsPublished',
                N'If replication is installed, SQL Server supports database table publication for snapshot or transactional replication.'),
            ('IsRecursiveTriggersEnabled',
                N'Recursive firing of triggers is enabled.'),
            ('IsSubscribed',
                N'Database is subscribed to a publication.'),
            ('IsSyncWithBackup',
                N'The database is either a published database or a distribution database, and it supports a restore that will not disrupt transactional replication.'),
            ('IsTornPageDetectionEnabled',
                N'The SQL Server Database Engine detects incomplete I/O operations caused by power failures or other system outages.'),
            ('IsVerifiedClone',
                N'2016SP2+; Database is a schema- and statistics- only copy of a user database, created using the WITH VERIFY_CLONEDB option of DBCC CLONEDATABASE.'),
            ('IsXTPSupported',
                N'2016+; Indicates whether the database supports In-Memory OLTP, i.e., creation and use of memory-optimized tables and natively compiled modules.'),
            ('LastGoodCheckDbTime',
                N'The date and time of the last successful DBCC CHECKDB that ran on the specified database. If DBCC CHECKDB has not been run on a database, 1900-01-01 00:00:00.000 is returned.'),
            ('LCID',
                N'The collation Windows locale identifier (LCID).'),
            ('MaxSizeInBytes',
                N'Azure SQLDB; Maximum database size, in bytes.'),
            ('Recovery',
                N'Database recovery model'),
            ('ServiceObjective',
                N'Azure SQLDB; Describes the performance level of the database.'),
            ('ServiceObjectiveId',
                N'Azure SQLDB; The guid of the service objective in SQL Database.'),
            ('SQLSortOrder',
                N'SQL Server sort order ID supported in earlier versions of SQL Server.'),
            ('Status',
                N'Database status: ONLINE, OFFLINE, RESTORING, RECOVERING, SUSPECT, EMERGENCY'),
            ('Updateability',
                N'Indicates whether data can be modified.'),
            ('UserAccess',
                N'Indicates which users can access the database.'),
            ('Version',
                N'Internal version number of the SQL Server code with which the database was created. Identified for informational purposes only. Not supported. Future compatibility is not guaranteed.')
        ) AS x(PropertyName, HelpText)
)
SELECT DbName = d.name, 
        dbp.*
FROM sys.databases AS d
OUTER APPLY (SELECT p.PropertyName,
                    PropertyValue = CONVERT(nvarchar(128),
                                        DATABASEPROPERTYEX(d.name, p.PropertyName)),
                    p.HelpText
            FROM DbProperties p) AS dbp(PropertyName, PropertyValue, HelpText);
GO
