CREATE OR ALTER FUNCTION dbo.HtmlDecode_Get
(
    @Text nvarchar(max)
)
RETURNS nvarchar(max)
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20261101
    Reverses the HTML character encoding produced by dbo.HtmlEncode_Get.

PARAMETERS
* @Text - Input text. NULL returns NULL.

EXAMPLES:
SELECT dbo.HtmlDecode_Get(N'&lt;b&gt;not markup&lt;/b&gt;');

**************************************************************************************************
MODIFICATIONS:
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
BEGIN
    IF @Text IS NULL
    BEGIN
        RETURN NULL;
    END;

    RETURN REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@Text, N'&lt;', N'<'), N'&gt;', N'>'), N'&quot;', N'"'), N'&#39;', N''''), N'&amp;', N'&');
END;
GO
