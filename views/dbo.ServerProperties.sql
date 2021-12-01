IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'V' AND object_id = object_id('dbo.ServerProperties'))
    EXEC ('CREATE VIEW dbo.ServerProperties AS SELECT Result = ''This is a stub'';' )
GO

ALTER VIEW dbo.ServerProperties
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 2021130
    EAV-style view to display all server properties, normally accessed via SERVERPROPERTY().
    Includes server properties for all supported versions. If the current server is older
    and does not support that server property, the PropertyValue will be NULL. See the HelpText
    for an indication of limited version support.

    Returned columns:
    * PropertyName - Name of the server property, passed as the argument to the SERVERPROPERTY() function.
    * PropertyValue - Value returned by the SERVERPROPERTY() function.
    * HelpText - Summary of property definition, and version/edition limitations. 

**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/production/LICENSE
    ©2014-2022 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
SELECT 
        PropertyName,
        PropertyValue       = CONVERT(nvarchar(128), PropertyValue),
        HelpText
FROM (
    VALUES
        ('BuildClrVersion'                 , SERVERPROPERTY('BuildClrVersion')                 ,
            'Version of the Microsoft.NET Framework common language runtime (CLR) that was used while building the instance of SQL Server.'),
        ('Collation'                       , SERVERPROPERTY('Collation')                       ,
            'Name of the default collation for the server.'),
        ('CollationID'                     , SERVERPROPERTY('CollationID')                     ,
            'ID of the SQL Server collation.'),
        ('ComparisonStyle'                 , SERVERPROPERTY('ComparisonStyle')                 ,
            'Windows comparison style of the collation.'),
        ('ComputerNamePhysicalNetBIOS'     , SERVERPROPERTY('ComputerNamePhysicalNetBIOS')     ,
            'NetBIOS name of the local computer on which the instance of SQL Server is currently running; For a failover clustered instance, this value changes as the instance fails over between cluster nodes.'),
        ('Edition'                         , SERVERPROPERTY('Edition')                         ,
            'Installed product edition of the instance of SQL Server.'),
        ('EditionID'                       , SERVERPROPERTY('EditionID')                       ,
            'EditionID is a bigint representation of the installed product edition of the instance of SQL Server'),
        ('EngineEdition'                   , SERVERPROPERTY('EngineEdition')                   ,
            'Database Engine edition of the instance of SQL Server installed on the server.'),
        ('FilestreamConfiguredLevel'       , SERVERPROPERTY('FilestreamConfiguredLevel')       ,
            'The configured level of FILESTREAM access.'),
        ('FilestreamEffectiveLevel'        , SERVERPROPERTY('FilestreamEffectiveLevel')        ,
            'The effective level of FILESTREAM access. This value can be different than the FilestreamConfiguredLevel if the level has changed and either an instance restart or a computer restart is pending.'),
        ('FilestreamShareName'             , SERVERPROPERTY('FilestreamShareName')             ,
            'The name of the share used by FILESTREAM.'),
        ('HadrManagerStatus'               , SERVERPROPERTY('HadrManagerStatus')               ,
            '2012+; Indicates whether the Always On availability groups manager has started.'),
        ('InstanceDefaultBackupPath'       , SERVERPROPERTY('InstanceDefaultBackupPath')       ,
            '2019+; Name of the default path to the instance backup files.'),
        ('InstanceDefaultDataPath'         , SERVERPROPERTY('InstanceDefaultDataPath')         ,
            '2012+; Name of the default path to the instance data files.'),
        ('InstanceDefaultLogPath'          , SERVERPROPERTY('InstanceDefaultLogPath')          ,
            '2012+; Name of the default path to the instance log files.'),
        ('InstanceName'                    , SERVERPROPERTY('InstanceName')                    ,
            'Name of the instance.'),
        ('IsAdvancedAnalyticsInstalled'    , SERVERPROPERTY('IsAdvancedAnalyticsInstalled')    ,
            'Returns 1 if the Advanced Analytics feature was installed during setup; 0 if Advanced Analytics was not installed.'),
        ('IsBigDataCluster'                , SERVERPROPERTY('IsBigDataCluster')                ,
            '2019 CU4+; Returns 1 if the instance is SQL Server Big Data Cluster; 0 if not.'),
        ('IsClustered'                     , SERVERPROPERTY('IsClustered')                     ,
            'Server instance is configured in a failover cluster.'),
        ('IsExternalAuthenticationOnly'    , SERVERPROPERTY('IsExternalAuthenticationOnly')    ,
            'Azure SQLDB & MI only; Returns whether Azure AD-only authentication is enabled.'),
        ('IsFullTextInstalled'             , SERVERPROPERTY('IsFullTextInstalled')             ,
            '	The full-text and semantic indexing components are installed on the current instance of SQL Server.'),
        ('IsHadrEnabled'                   , SERVERPROPERTY('IsHadrEnabled')                   ,
            '2012+; Always On availability groups is enabled on this server instance.'),
        ('IsIntegratedSecurityOnly'        , SERVERPROPERTY('IsIntegratedSecurityOnly')        ,
            'Server is in integrated security mode.'),
        ('IsLocalDB'                       , SERVERPROPERTY('IsLocalDB')                       ,
            '2012+; Server is an instance of SQL Server Express LocalDB.'),
        ('IsPolyBaseInstalled'             , SERVERPROPERTY('IsPolyBaseInstalled')             ,
            '2016+; Returns whether the server instance has the PolyBase feature installed.'),
        ('IsSingleUser'                    , SERVERPROPERTY('IsSingleUser')                    ,
            'Server is in single-user mode.'),
        ('IsTempDbMetadataMemoryOptimized' , SERVERPROPERTY('IsTempDbMetadataMemoryOptimized') ,
            '2019+; Returns 1 if tempdb has been enabled to use memory-optimized tables for metadata; 0 if tempdb is using regular, disk-based tables for metadata.'),
        ('IsXTPSupported'                  , SERVERPROPERTY('IsXTPSupported')                  ,
            '2014+; Server supports In-Memory OLTP.'),
        ('LCID'                            , SERVERPROPERTY('LCID')                            ,
            'Windows locale identifier (LCID) of the collation.'),
        ('LicenseType'                     , SERVERPROPERTY('LicenseType')                     ,
            'Unused. License information is not preserved or maintained by the SQL Server product. Always returns DISABLED.'),
        ('MachineName'                     , SERVERPROPERTY('MachineName')                     ,
            'Windows computer name on which the server instance is running. For a failover clustered instance, this value returns the name of the virtual server.'),
        ('NumLicenses'                     , SERVERPROPERTY('NumLicenses')                     ,
            'Unused. License information is not preserved or maintained by the SQL Server product. Always returns NULL.'),
        ('ProcessID'                       , SERVERPROPERTY('ProcessID')                       ,
            'Process ID of the SQL Server service. ProcessID is useful in identifying which Sqlservr.exe belongs to this instance.'),
        ('ProductBuild'                    , SERVERPROPERTY('ProductBuild')                    ,
            '2014+; The build number.'),
        ('ProductBuildType'                , SERVERPROPERTY('ProductBuildType')                ,
            'Type of build of the current build. OD = On Demand release a specific customer. GDR = General Distribution Release released through Windows Update.'),
        ('ProductLevel'                    , SERVERPROPERTY('ProductLevel')                    ,
            'Level of the version of the instance of SQL Server. RTM = Original release version. SP = Service pack version. CTP = Community Technology Preview version.'),
        ('ProductMajorVersion'             , SERVERPROPERTY('ProductMajorVersion')             ,
            '2012+; The major version.'),
        ('ProductMinorVersion'             , SERVERPROPERTY('ProductMinorVersion')             ,
            '2012+; The minor version.'),
        ('ProductUpdateLevel'              , SERVERPROPERTY('ProductUpdateLevel')              ,
            '2012+; Update level of the current build. CU indicates a cumulative update.'),
        ('ProductUpdateReference'          , SERVERPROPERTY('ProductUpdateReference')          ,
            '2012+; KB article for that release.'),
        ('ProductVersion'                  , SERVERPROPERTY('ProductVersion')                  ,
            'Version of the instance of SQL Server, in the form of [major.minor.build.revision].'),
        ('ResourceLastUpdateDateTime'      , SERVERPROPERTY('ResourceLastUpdateDateTime')      ,
            'Returns the date and time that the Resource database was last updated.'),
        ('ResourceVersion'                 , SERVERPROPERTY('ResourceVersion')                 ,
            'Returns the version Resource database.'),
        ('ServerName'                      , SERVERPROPERTY('ServerName')                      ,
            'Both the Windows server and instance information associated with a specified instance of SQL Server.'),
        ('SqlCharSet'                      , SERVERPROPERTY('SqlCharSet')                      ,
            'The SQL character set ID from the collation ID.'),
        ('SqlCharSetName'                  , SERVERPROPERTY('SqlCharSetName')                  ,
            'The SQL character set name from the collation.'),
        ('SqlSortOrder'                    , SERVERPROPERTY('SqlSortOrder')                    ,
            'The SQL sort order ID from the collation'),
        ('SqlSortOrderName'                , SERVERPROPERTY('SqlSortOrderName')                ,
            'The SQL sort order name from the collation.')
    ) AS ServerProperties (PropertyName, PropertyValue, HelpText);
GO
