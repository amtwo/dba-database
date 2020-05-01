--dbo.Alert_Blocking stored procedure will log blocking to this table.
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
        CONSTRAINT PK_Monitor_Blocking PRIMARY KEY CLUSTERED (LogDateTime,LogId )
    ) ON [DATA];
END
GO



