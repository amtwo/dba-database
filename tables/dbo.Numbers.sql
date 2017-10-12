IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'Numbers')
BEGIN
    CREATE TABLE dbo.Numbers (
        Number int identity(1,1),
        CONSTRAINT PK_Number PRIMARY KEY CLUSTERED (Number)
        );
END;


--populate it with exactly 1 million rows. https://goo.gl/VJyNi6
IF (SELECT COUNT(*) FROM dbo.Numbers) <> 1000000
BEGIN
    TRUNCATE TABLE dbo.Numbers;
    SET IDENTITY_INSERT dbo.Numbers ON;
    INSERT INTO dbo.Numbers (Number)
    SELECT TOP 1000000 ROW_NUMBER() OVER (ORDER BY o1.object_id)
    FROM sys.objects o1, sys.objects o2, sys.objects o3;
    SET IDENTITY_INSERT dbo.Numbers OFF;
END;

