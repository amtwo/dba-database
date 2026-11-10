IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'V' AND object_id = object_id('dbo.ServerLoginPermissions'))
BEGIN
    EXEC ('CREATE VIEW dbo.ServerLoginPermissions AS SELECT Result = ''This is a stub'';' );
END;
GO

ALTER VIEW dbo.ServerLoginPermissions
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20210627
    View to get basic info for server-level permissions, simplifying/flattening DMVs, to make applying additional 
    criteria/filters from automation & troubleshooting easier.
    CanLogIn indicates an enabled login with a visible, explicit CONNECT SQL grant.
    PermissionSql scripts server, login, server role, and endpoint permissions. Run the commands in master.
    Other securable classes or entries with hidden targets return NULL in PermissionSql.
EXAMPLES:
* Get GRANT/DENY commands for permissions on all enabled users
    SELECT p.LoginName, p.PermissionSql
    FROM dbo.ServerLoginPermissions AS p
    JOIN dbo.ServerLogins AS l ON l.LoginSid = p.LoginSid
    WHERE l.IsEnabled = 1 AND p.PermissionSql IS NOT NULL;
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
            PermissionSql           = CASE
                                           WHEN securable.Clause IS NOT NULL AND perm.state IN ('D', 'R', 'G', 'W')
                                           THEN CONCAT(
                                               CASE WHEN perm.state = 'W' THEN N'GRANT' ELSE perm.state_desc END,
                                               N' ', perm.permission_name, securable.Clause,
                                               CASE WHEN perm.state = 'R' THEN N' FROM ' ELSE N' TO ' END,
                                               QUOTENAME(p.name) COLLATE Latin1_General_CI_AS_KS_WS,
                                               CASE WHEN perm.state = 'W' THEN N' WITH GRANT OPTION' ELSE N'' END,
                                               N';')
                                       END,
            DateLoginCreated        = p.create_date,
            DateLoginModified       = p.modify_date
    FROM sys.server_principals AS p
    JOIN sys.server_permissions AS perm 
        ON perm.grantee_principal_id = p.principal_id
    LEFT JOIN sys.server_principals AS targetPrincipal
        ON perm.class = 101 AND targetPrincipal.principal_id = perm.major_id
    LEFT JOIN sys.endpoints AS ep
        ON perm.class = 105 AND ep.endpoint_id = perm.major_id
    CROSS APPLY (VALUES (
        CASE perm.class
            WHEN 100 THEN N''
            WHEN 101 THEN CASE WHEN targetPrincipal.type = 'R' THEN N' ON SERVER ROLE::' ELSE N' ON LOGIN::' END
                          + QUOTENAME(targetPrincipal.name)
            WHEN 105 THEN N' ON ENDPOINT::' + QUOTENAME(ep.name)
        END COLLATE Latin1_General_CI_AS_KS_WS
    )) AS securable(Clause)
    WHERE p.type IN ('S','U','G')
    AND p.name <> N'sa'
    AND p.name NOT LIKE N'##%##';
GO
