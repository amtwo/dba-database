IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'V' AND object_id = object_id('dbo.CmsGroups'))
    EXEC ('CREATE VIEW dbo.CmsGroups AS SELECT ''This is a stub''')
GO
ALTER VIEW dbo.CmsGroups
AS
WITH ServerGroups AS (
    SELECT  GroupID     = cms1.server_group_id,
            GroupName   = cms1.name,
            GroupDesc   = cms1.description,
            ParentID    = cms1.parent_id,
            GroupPath   = CONVERT(nvarchar(1000),cms1.name)
    FROM msdb.dbo.sysmanagement_shared_server_groups AS cms1
    WHERE parent_id IS NULL
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
SELECT *
FROM ServerGroups;
GO