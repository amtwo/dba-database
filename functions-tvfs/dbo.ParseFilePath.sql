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
    This code is licensed under the GNU GPL, as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2019 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
RETURN
    WITH ParseInfo AS(
        SELECT FilePath      = @FilePath,
               PathLen       = LEN(@FilePath),
               FinalSlashPos = CHARINDEX('\', REVERSE(@FilePath), 1)
        ),
        ParsedPaths AS (
        SELECT DirectoryPath = LEFT (FilePath, PathLen - FinalSlashPos + 1),
               FullFileName  = RIGHT(FilePath, FinalSlashPos - 1),
               FileExtension = RIGHT(FilePath, CHARINDEX('.', REVERSE(FilePath)) -1),
               *
        FROM ParseInfo
        )
    SELECT DirectoryPath,
           FullFileName,
           BareFilename = LEFT(FullFilename,LEN(FullFilename)-(LEN(FileExtension)+1)),
           FileExtension
    FROM ParsedPaths;

GO


