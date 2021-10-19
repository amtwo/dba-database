IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'IF' AND object_id = object_id('dbo.fn_split'))
    EXEC ('CREATE FUNCTION dbo.fn_split() RETURNS TABLE AS RETURN SELECT Result = ''This is a stub'';' )
GO


ALTER FUNCTION dbo.fn_split (@Text nvarchar(8000), @Token nvarchar(20) = N',')
RETURNS TABLE
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20140420
    Convert a delimited string (any delimiter can be passed, default assumes CSV.
    Use method of converting the CSV value into an XML document to make shredding more efficient.

    If you are using SQL Server 2016 or later, with compatibility level 130 or higher, 
    use STRING_SPLIT() instead.
PARAMETERS:
    @Text - Text string of delimited text
    @Token - Default , - Delimited used to parse the @Text string
EXAMPLES:
* SELECT * FROM dbo.fn_split('A,B,C',default)
* SELECT * FROM dbo.fn_split('A|^B|^C','|^')
**************************************************************************************************
MODIFICATIONS:
    20211019 - Updated to support Unicode lists (such as a list of database names)
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
RETURN
SELECT ID, Value
FROM (
    SELECT ID = m.n.value('for $i in . return count(../*[. << $i]) + 1', 'int')
        , Value = LTRIM(RTRIM(m.n.value('.[1]','nvarchar(4000)')))
    FROM (
        SELECT CAST('<XMLRoot><RowData>' + REPLACE(@Text,@Token,'</RowData><RowData>') + '</RowData></XMLRoot>' AS XML) AS x
        )t
    CROSS APPLY x.nodes('/XMLRoot/RowData')m(n)
    ) AS R
GO


