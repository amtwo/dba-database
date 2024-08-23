IF NOT EXISTS (SELECT 1 FROM sys.types WHERE user_type_id = type_id ('dbo.ObjectNameListWithDb'))
BEGIN
    CREATE TYPE dbo.ObjectNameListWithDb
        AS TABLE(
            DbName     sysname,
            SchemaName sysname,
            ObjectName sysname
        );
END;
GO
