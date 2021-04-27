IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'IF' AND object_id = object_id('dbo.Convert_LSNFromHexToDecimal'))
    EXEC ('CREATE FUNCTION dbo.Convert_LSNFromHexToDecimal() RETURNS TABLE AS RETURN SELECT Result = ''This is a stub'';' )
GO


ALTER FUNCTION dbo.Convert_LSNFromHexToDecimal (@LSN varchar(22))
RETURNS TABLE
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20190401
    LSN is sometimes represented in hex (ie, from DBCC PAGE, fn_dblog(), sys.dm_db_page_info)
    Hex LSNs are represented in the format '0000001e:00000038:0001'
    Decimal LSNs are in the format 30000000005600001
PARAMETERS:
    @LSN - Text string of the hex version of the LSN
           In the format '0000001e:00000038:0001' 
EXAMPLES:
* SELECT * FROM dbo.Convert_LSNFromHexToDecimal(0000001e:00000038:0001')
**************************************************************************************************
MODIFICATIONS:
    20190401 - 
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/

-- Split LSN into segments at colon
-- Convert to binary style 1 -> int
-- Add padded 0's to 2nd and 3rd string
-- Concatenate those strings & convert back to int

RETURN
    --First chunk
    SELECT LSN  = CONVERT(decimal(25),
                    CONVERT(varchar(10),
                            CONVERT(int,
                                        CONVERT(varbinary, '0x' + RIGHT(REPLICATE('0', 8) + LEFT(@LSN, 8), 8), 1) 
                                    ) 
                            )
    --Second chunk
                + RIGHT(REPLICATE('0', 10) + CONVERT(varchar(10),
                                                        CONVERT(int,
                                                                    CONVERT(varbinary, '0x' + RIGHT(REPLICATE('0', 8) + SUBSTRING(@LSN, 10, 8), 8), 1) 
                                                                ) 
                                                    ), 
                        10)
    --Third chunk
                + RIGHT(REPLICATE('0', 5) + CONVERT(varchar(5), 
                                                        CONVERT(int, 
                                                                    CONVERT(varbinary, '0x' + RIGHT(REPLICATE('0', 8) + RIGHT(@LSN, 4), 8), 1) 
                                                                ) 
                                                    ), 
                        5)
                    );
GO