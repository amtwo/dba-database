IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'V' AND object_id = object_id('dbo.ServerLoginPermissions'))
    EXEC ('CREATE VIEW dbo.ServerLoginPermissions AS SELECT Result = ''This is a stub'';' )
GO

ALTER VIEW dbo.ServerLoginPermissions
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20210627
    View to get basic info for server-level permissions, simplifying/flattening DMVs, to make applying additional 
    criteria/filters from automation & troubleshooting easier
EXAMPLES:
* Get GRANT/DENY commands for permissions on all enabled users
    SELECT p.LoginName, p.PermissionSql
    FROM dbo.ServerLoginPermissions AS p
    JOIN dbo.ServerLogins AS l ON l.LoginSid = p.LoginSid
    WHERE l.IsEnabled = 1;
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
    SELECT 
            LoginSid                = p.sid, 
            LoginName               = p.name, 
            LoginType               = p.type_desc,
            DefaultDatabase         = p.default_database_name,
            LoginIsEnabled          = IIF(p.is_disabled = 0,1,0),
            CanLogIn                = COALESCE((SELECT TOP 1 1 FROM sys.server_permissions AS cosq
                                                WHERE cosq.grantee_principal_id = p.principal_id
                                                AND cosq.type = 'COSQ' 
                                                AND cosq.state IN ('G','W')
                                                AND p.is_disabled = 0
                                                ),
                                        0),
            PermissionType          = perm.type,
            PermissionState         = perm.state,
            PermissionSql           = CONCAT(perm.state_desc, N' ',
                                                perm.permission_name, N' TO ',
                                                QUOTENAME(p.name) COLLATE Latin1_General_CI_AS_KS_WS, 
                                                N';'
                                                ),
            DateLoginCreated        = p.create_date,
            DateLoginModified       = p.modify_date
    FROM sys.server_principals AS p
    JOIN sys.server_permissions AS perm 
        ON perm.grantee_principal_id = p.principal_id
    WHERE p.type IN ('S','U','G')
    AND p.name <> N'sa'
    AND p.name NOT LIKE N'##%##';
GO
