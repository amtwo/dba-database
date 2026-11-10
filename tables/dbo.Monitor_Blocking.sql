--dbo.Alert_Blocking stores blocking details and the associated email attempt lifecycle in this table.
--EmailStatus values include sending, queued, error, and debug; queued means accepted by Database Mail, not confirmed delivered.
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = object_id('dbo.Monitor_Blocking'))
BEGIN
    CREATE TABLE dbo.Monitor_Blocking(
        LogId               int IDENTITY(1,1) NOT NULL,
        LogDateTime         datetime2(0) NOT NULL CONSTRAINT DF_Monitor_Blocking_LogDateTime DEFAULT getdate(),
        LeadingBlocker      smallint NULL,
        BlockedSpidCount    int NULL,
        DbName              sysname NOT NULL,
        HostName            nvarchar(128) NULL,
        ProgramName         nvarchar(128) NULL,
        LoginName           nvarchar(128) NULL,
        LoginTime           datetime2(3) NULL,
        LastRequestStart    datetime2(3) NULL,
        LastRequestEnd      datetime2(3) NULL,
        TransactionCnt      int NULL,
        Command             nvarchar(32) NULL,
        WaitTime            int NULL,
        WaitResource        nvarchar(256) NULL,
        SqlText             nvarchar(max) NULL,
        InputBuffer         nvarchar(4000) NULL,
        SqlStatement        nvarchar(max) NULL,
        AlertId             uniqueidentifier NULL,
        AlertRecipients     varchar(max) NULL,
        EmailAttemptDateTime datetime2(3) NULL,
        EmailQueuedDateTime  datetime2(3) NULL,
        EmailStatus          varchar(16) NULL,
        DatabaseMailItemId   int NULL,
        EmailError           nvarchar(4000) NULL,
        CONSTRAINT PK_Monitor_Blocking PRIMARY KEY CLUSTERED (LogDateTime,LogId )
    ) ON [DATA];
END
GO

IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = object_id('dbo.Monitor_Blocking') AND name = 'AlertId')
BEGIN
    ALTER TABLE dbo.Monitor_Blocking ADD AlertId uniqueidentifier NULL;
END;
GO

IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = object_id('dbo.Monitor_Blocking') AND name = 'AlertRecipients')
BEGIN
    ALTER TABLE dbo.Monitor_Blocking ADD AlertRecipients varchar(max) NULL;
END;
GO

IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = object_id('dbo.Monitor_Blocking') AND name = 'EmailAttemptDateTime')
BEGIN
    ALTER TABLE dbo.Monitor_Blocking ADD EmailAttemptDateTime datetime2(3) NULL;
END;
GO

IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = object_id('dbo.Monitor_Blocking') AND name = 'EmailQueuedDateTime')
BEGIN
    ALTER TABLE dbo.Monitor_Blocking ADD EmailQueuedDateTime datetime2(3) NULL;
END;
GO

IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = object_id('dbo.Monitor_Blocking') AND name = 'EmailStatus')
BEGIN
    ALTER TABLE dbo.Monitor_Blocking ADD EmailStatus varchar(16) NULL;
END;
GO

IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = object_id('dbo.Monitor_Blocking') AND name = 'DatabaseMailItemId')
BEGIN
    ALTER TABLE dbo.Monitor_Blocking ADD DatabaseMailItemId int NULL;
END;
GO

IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = object_id('dbo.Monitor_Blocking') AND name = 'EmailError')
BEGIN
    ALTER TABLE dbo.Monitor_Blocking ADD EmailError nvarchar(4000) NULL;
END;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.Monitor_Blocking')
    AND name = 'IX_Monitor_Blocking_EmailAttemptDateTime_Sending'
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_Monitor_Blocking_EmailAttemptDateTime_Sending
        ON dbo.Monitor_Blocking (EmailAttemptDateTime)
        WHERE EmailStatus = 'sending';
END;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.Monitor_Blocking')
    AND name = 'IX_Monitor_Blocking_EmailQueuedDateTime_Queued'
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_Monitor_Blocking_EmailQueuedDateTime_Queued
        ON dbo.Monitor_Blocking (EmailQueuedDateTime)
        WHERE EmailStatus = 'queued';
END;
GO



