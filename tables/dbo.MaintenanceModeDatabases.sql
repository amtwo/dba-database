
IF EXISTS (SELECT 1 FROM sys.tables t INNER JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE t.name = 'MaintenanceModeDatabases' AND s.name = 'dbo') DROP TABLE dbo.MaintenanceModeDatabases;
CREATE TABLE MaintenanceModeDatabases (
	DatabaseName NVARCHAR(128), 
	AddedByUser NVARCHAR(100), 
	AddedDateTimeUTC DATETIME DEFAULT GETUTCDATE()
	);
GO



