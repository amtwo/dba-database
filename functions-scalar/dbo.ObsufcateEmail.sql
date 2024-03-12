CREATE OR ALTER FUNCTION dbo.ObsufcateEmail(@Email NVARCHAR(100))
RETURNS NVARCHAR(100)
AS
/*************************************************************************************************
AUTHOR: Patrick Hurst
CREATED: 20220414
    Obsfucates the provided Email address by returning the first two characters of the user name,
	the first two characters of the domain and the complete TLD. If the value does not contain a 
	@ calls dbo.ObsfucateString instead.
PARAMETERS:
    @Email - the Email Address to obsfucate
EXAMPLES:
*   dbo.ObsufcateEmail('phurst@stackoverflow.com') --> phXXXX@stXXXXXXXXXXX.com
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDD - 
**************************************************************************************************

*************************************************************************************************/
  BEGIN
   DECLARE @return NVARCHAR(100)
   SELECT @return = CASE WHEN CHARINDEX('@', @Email) > 1 THEN REPLACE(LEFT(@Email,2),'@','')    +COALESCE(REPLICATE('X',CHARINDEX('@',@Email)-3),'')+'@'+
   LEFT(RIGHT(@Email,LEN(@Email)-CHARINDEX('@',@Email)),2)+REPLICATE('X',CHARINDEX('.',RIGHT(@Email,LEN(@Email)-CHARINDEX('@',@Email)-3)))+
   RIGHT(@Email,LEN(RIGHT(@Email,LEN(@Email)-CHARINDEX('@',@Email)))-CHARINDEX('.',RIGHT(@Email,LEN(@Email)-CHARINDEX('@',@Email)))+1) ELSE dbo.ObsfucateString(@Email) END
   RETURN @return
  END