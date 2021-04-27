IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'V' AND object_id = object_id('dbo.CmsServers'))
    EXEC ('CREATE VIEW dbo.CmsServers AS SELECT Stub = ''This is a stub''')
GO
ALTER VIEW dbo.CmsServers
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
WITH ServerGroups AS (
    SELECT  GroupID     = cms1.server_group_id,
            GroupName   = cms1.name,
            GroupDesc   = cms1.description,
            ParentID    = cms1.parent_id,
            GroupPath   = CONVERT(nvarchar(1000),cms1.name)
    FROM msdb.dbo.sysmanagement_shared_server_groups AS cms1
    WHERE cms1.parent_id = 1
    UNION ALL
    SELECT  GroupID     = cms2.server_group_id,
            GroupName   = cms2.name,
            GroupDesc   = cms2.description,
            ParentID    = cms2.parent_id,
            CONVERT(nvarchar(1000),sg.GroupPath + N'\' + cms2.name)
    FROM ServerGroups AS sg
    JOIN msdb.dbo.sysmanagement_shared_server_groups AS cms2
        ON cms2.parent_id = sg.GroupID
    )
SELECT  ServerID    = rs.server_id,
        ServerName  = rs.server_name,
        DisplayName = rs.name,
        ServerDesc  = rs.description,
        GroupID     = rs.server_group_id,
        GroupName   = sg.GroupName,
        GroupDesc   = sg.GroupDesc,
        ServerPath  = sg.GroupPath
FROM ServerGroups AS sg
JOIN msdb.dbo.sysmanagement_shared_registered_servers AS rs
    ON sg.GroupID = rs.server_group_id;
GO