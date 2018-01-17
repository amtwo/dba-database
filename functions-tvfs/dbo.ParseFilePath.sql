IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'IF' AND object_id = object_id('dbo.ParseFilePath'))
    EXEC ('CREATE FUNCTION dbo.ParseFilePath() RETURNS TABLE AS RETURN SELECT Result = ''This is a stub'';' )
GO


ALTER FUNCTION dbo.ParseFilePath (@FilePath nvarchar(300))
RETURNS TABLE
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20180114
    Parses a full file path into separate file & path values. 
    Also include the bare file name & file extension, because why not?
PARAMETERS:
    @FilePath - Text string of a complete file & path
EXAMPLES:
* 
**************************************************************************************************
MODIFICATIONS:
    20160218 - 
**************************************************************************************************
    This code is free to download and use for personal, educational, and internal 
    corporate purposes, provided that this header is preserved. Redistribution or sale, 
    in whole or in part, is prohibited without the author's express written consent.
    ©2014-2017 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
RETURN
    SELECT DirectoryPath = LEFT (@FilePath, LEN(@FilePath) - CHARINDEX('\', REVERSE(@FilePath), 1) + 1), 
           FullFileName  = RIGHT(@FilePath, CHARINDEX('\', REVERSE(@FilePath)) -1),
           BareFileName  = LEFT(RIGHT(@FilePath, CHARINDEX('\', REVERSE(@FilePath)) -1), 
                                LEN(RIGHT(@FilePath, CHARINDEX('\', REVERSE(@FilePath)) -1)) 
                                    - CHARINDEX('.', REVERSE(RIGHT(@FilePath, CHARINDEX('\', REVERSE(@FilePath)) -1))) ),
           FileExtension = RIGHT(@FilePath, CHARINDEX('.', REVERSE(@FilePath)) -1);
GO


