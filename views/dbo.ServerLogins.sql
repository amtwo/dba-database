IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'V' AND object_id = object_id('dbo.ServerLogins'))
    EXEC ('CREATE VIEW dbo.ServerLogins AS SELECT Result = ''This is a stub'';' )
GO

ALTER VIEW dbo.ServerLogins
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20210627
    View to get basic info for logins, simplifying/flattening DMVs, to make applying additional 
    criteria/filters from automation & troubleshooting easier
EXAMPLES:
* All logins that can log in (enabled + have CONNECT SQL), modified in the last 7 days:
    SELECT LoginName, DateModified, CreateSql
    FROM dbo.ServerLogins
    WHERE CanLogIn = 1
    AND DateModified >= DATEADD(DAY, -7, GETUTCDATE())
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
            VarbinaryPasswordHash   = sl.password_hash,
            IsPolicyChecked         = IIF(sl.is_policy_checked=1,1,0),
            IsExpirationChecked     = IIF(sl.is_expiration_checked=1,1,0),
            IsEnabled               = IIF(p.is_disabled = 0,1,0),
            CanLogIn                = IIF(perm.state IN ('G','W'),1,0),
            CreateSql               = CASE
                                        WHEN p.type IN ('U','G')
                                            THEN CONCAT(N'CREATE LOGIN ', 
                                                     QUOTENAME(p.name),
                                                     N' FROM WINDOWS',
                                                     N' WITH DEFAULT_DATABASE = ',
                                                     QUOTENAME(p.default_database_name),
                                                     N';'
                                                 )
                                        WHEN p.type = 'S'
                                            THEN CONCAT(N'CREATE LOGIN ', 
                                                     QUOTENAME(p.name),
                                                     N' WITH PASSWORD = ',
                                                     CONVERT(varchar(512), sl.password_hash, 1),
                                                     N' HASHED, SID = ',
                                                     CONVERT(varchar(512), p.sid, 1),
                                                     N', DEFAULT_DATABASE = ',
                                                     QUOTENAME(p.default_database_name),
                                                     N', CHECK_POLICY = ',
                                                     IIF(sl.is_policy_checked=1,N'ON','OFF'),
                                                     N', CHECK_EXPIRATION = ',
                                                     IIF(sl.is_expiration_checked=1,N'ON','OFF'),
                                                     N';'
                                                 )
                                      END,
            DateCreated             = p.create_date,
            DateModified            = p.modify_date
            FROM sys.server_principals AS p
            LEFT JOIN sys.sql_logins AS sl 
                ON p.name = sl.name
            --Left join here to check to determine if the login is enabled & has connect SQL
            LEFT JOIN sys.server_permissions AS perm 
                ON perm.grantee_principal_id = p.principal_id
                AND perm.type = 'COSQ' 
                AND perm.state IN ('G','W')
                AND p.is_disabled = 0
            WHERE p.type IN ('S','U','G')
            AND p.name <> N'sa'
            AND p.name NOT LIKE N'##%##';
GO
