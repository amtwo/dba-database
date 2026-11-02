CREATE OR ALTER FUNCTION dbo.HtmlEncode_Get
(
    @Text nvarchar(max)
)
RETURNS nvarchar(max)
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20261101
    Encodes text values for safe insertion into HTML text content.

PARAMETERS
* @Text - Input text. NULL returns NULL.

EXAMPLES:
SELECT dbo.HtmlEncode_Get(N'<b>not markup</b>');

**************************************************************************************************
MODIFICATIONS:
    20261101 - AM2 - Add reusable HTML encoding for alert content.
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
BEGIN
    IF @Text IS NULL
        RETURN NULL;

    RETURN REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@Text, N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), N'"', N'&quot;'), N'''', N'&#39;');
END;
GO
