CREATE OR ALTER FUNCTION dbo.ObsfucateIPAddress(@String NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
/*************************************************************************************************
AUTHOR: Patrick Hurst
CREATED: 20220414
    Obsfucates the provided IP by returning the first digit of each octet and replacing the 
	rest with Xs
PARAMETERS:
    @String - the IP Address to obsfucate
EXAMPLES:
*   dbo.ObsfucateIPAddress('192.168.1.10') --> 1XX.1XX.1.1X
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDD - 
**************************************************************************************************

*************************************************************************************************/
  BEGIN
    DECLARE @return NVARCHAR(MAX)
    SELECT @return = STRING_AGG(LEFT(value,1) +COALESCE(REPLICATE('X',LEN(Value)-1),''), '.')
	  FROM string_split(@String,'.')
	RETURN @return
  END
  GO
