IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'FN' AND object_id = object_id('dbo.EmailServerInfo_Get'))
    EXEC ('CREATE FUNCTION dbo.EmailServerInfo_Get() RETURNS nvarchar(60) AS BEGIN RETURN ''This is a stub''; END')
GO


ALTER FUNCTION dbo.EmailServerInfo_Get()
RETURNS nvarchar(max)
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20150107
    This function returns an HTML table containing standard info about a SQL instance to
    be included in email alerts/reports
    * Instance name
    * Physical Server
    * Instance start time

PARAMETERS
* None
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDDD - Initials - Description of changes
**************************************************************************************************
    This code is free to download and use for personal, educational, and internal 
    corporate purposes, provided that this header is preserved. Redistribution or sale, 
    in whole or in part, is prohibited without the author's express written consent.
    ©2014-2017 ● Andy Mallon ● am2.co
*************************************************************************************************/
BEGIN
    DECLARE @ServerInfo nvarchar(max);
    
    
    SELECT @ServerInfo = N'<table>
        <tr>
            <th> SQL Instance </th>
            <td> ' + @@SERVERNAME + N'</td>
        </tr><tr>
            <th> Physical Server </th>
            <td> ' + CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS nvarchar(128)) + N'</td>
        </tr><tr>
            <th> Instance Start Time </th>
            <td> ' + (SELECT CONVERT(nvarchar(20),create_date,120) FROM sys.databases WHERE Name = 'tempdb') + N'</td>
        </tr>
    </table>';

    RETURN(@ServerInfo);
END;
GO


