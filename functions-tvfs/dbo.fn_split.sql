IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'IF' AND object_id = object_id('dbo.fn_split'))
    EXEC ('CREATE FUNCTION dbo.fn_split() RETURNS TABLE AS RETURN SELECT Result = ''This is a stub'';' )
GO


ALTER FUNCTION dbo.fn_split (@Text nvarchar(4000), @Token nvarchar(20) = N',')
RETURNS TABLE
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20140420
    Convert a delimited string (any delimiter can be passed, default assumes CSV.
    XML metacharacters are escaped before the XML document is parsed.

    For a single-character delimiter and unordered output, use STRING_SPLIT() on SQL Server 2016 or
    later with compatibility level 130 or higher. Its optional ordinal argument is available only
    starting with SQL Server 2022. Keep this helper when you need a multicharacter delimiter or
    ordered results on an older SQL Server version.
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
        , Value = LTRIM(RTRIM(m.n.value('.', 'nvarchar(4000)')))
    FROM (
        SELECT x = CAST(
            N'<XMLRoot><RowData>'
            + REPLACE(
                REPLACE(
                    REPLACE(
                        REPLACE(CONVERT(nvarchar(max), @Text), @Token, m.Marker),
                        N'&', N'&amp;'),
                    N'<', N'&lt;'),
                N'>', N'&gt;') COLLATE Latin1_General_BIN,
                m.Marker COLLATE Latin1_General_BIN,
                N'</RowData><RowData>')
            + N'</RowData></XMLRoot>' AS XML)
        FROM (
            SELECT TOP (1) Marker = NCHAR(57344 + n)
            FROM (
                SELECT n = d1.Value * 1000 + d2.Value * 100 + d3.Value * 10 + d4.Value
                FROM (SELECT 0 AS Value UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                    UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) AS d1
                CROSS JOIN (SELECT 0 AS Value UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                    UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) AS d2
                CROSS JOIN (SELECT 0 AS Value UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                    UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) AS d3
                CROSS JOIN (SELECT 0 AS Value UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                    UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) AS d4
            ) AS Candidates
            WHERE n < 6400
                AND CHARINDEX(NCHAR(57344 + n) COLLATE Latin1_General_BIN, @Text COLLATE Latin1_General_BIN) = 0
            ORDER BY n
        ) AS m
        )t
    CROSS APPLY x.nodes('/XMLRoot/RowData')m(n)
    ) AS R
GO


