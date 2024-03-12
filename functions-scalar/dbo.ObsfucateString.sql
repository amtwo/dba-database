 CREATE OR ALTER FUNCTION dbo.ObsfucateString(@String NVARCHAR(MAX))
 RETURNS NVARCHAR(MAX)
 AS
/*************************************************************************************************
AUTHOR: Patrick Hurst
CREATED: 20220414
    Obsfucates the provided string by returning the first two characters of any word, and 
	replacing the rest with Xs
PARAMETERS:
    @String - the string to obsfucate
EXAMPLES:
*   dbo.ObsfucateString('John Smith') --> JoXX SmXXX
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDD - 
**************************************************************************************************

*************************************************************************************************/
  BEGIN
    DECLARE @return NVARCHAR(MAX)
    SELECT @return = STRING_AGG(LEFT(value,2) +COALESCE(REPLICATE('X',LEN(Value)-2),''), ' ')
	  FROM string_split(@String,' ')
	RETURN @return
  END
GO