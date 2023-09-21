IF NOT EXISTS (SELECT 1 FROM sys.types WHERE user_type_id = type_id ('dbo.ObjectNameList'))
BEGIN
    CREATE TYPE dbo.ObjectNameList
        AS TABLE(
            SchemaName sysname,
            ObjectName sysname
        );
END;
GO
