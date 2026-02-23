IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'IF' AND object_id = object_id('dbo.Dst_Dates'))
    EXEC ('CREATE FUNCTION dbo.Dst_Dates() RETURNS TABLE AS RETURN SELECT Result = ''This is a stub'';' )
GO


CREATE FUNCTION dbo.Dst_Dates(
			@InputDate DATE, 
			@Locality CHAR(3) = 'USA')
RETURNS TABLE
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260202
    For any given date input, returns the DST start & End dates.
PARAMETERS:
    @InputDate - A date for which we want to determine the DST dates.
    @Locality - Supports USA, EUR, and UK DST dates. Other locality rules not implemented.
EXAMPLES:
* 
**************************************************************************************************
MODIFICATIONS:
    20160218 - 
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
RETURN
(
	WITH 
		USA_DST AS (
			/* Current DST rules for USA since 2007*/
			SELECT 
				DstYear         = DATEPART(YEAR, @InputDate),
				/* Second Sunday in March */
				DstStartDate    = DATEADD(DAY, 
											(14 - DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 3, 1)) + 1) % 7 + 7,
											DATEFROMPARTS(YEAR(@InputDate), 3, 1)),
				/* First Sunday in November */
				DstEndDate      = DATEADD(DAY,
											(8 - DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 11, 1))) % 7,
											DATEFROMPARTS(YEAR(@InputDate), 11, 1))
			WHERE @InputDate >= '20070101'
			
			UNION ALL
			/* Legacy DST rules for USA since 1987-2006*/
			SELECT 
				DstYear         = DATEPART(YEAR, @InputDate),
				/* First Sunday in April */
				DstStartDate    = DATEADD(DAY, 
											(8 - DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 4, 1))) % 7, 
											DATEFROMPARTS(YEAR(@InputDate), 4, 1)),
				/* Last Sunday in October */
				DstEndDate      = DATEADD(DAY, 
											-1 * (DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 10, 31)) - 1), 
											DATEFROMPARTS(YEAR(@InputDate), 10, 31))
			WHERE @InputDate >= '19840101'
			  AND @InputDate <  '20070101'
			
			UNION ALL
			/* Uniform Time Act 1967-1987*/
			SELECT 
				DstYear         = DATEPART(YEAR, @InputDate),
				/* Last Sunday in April */
				DstStartDate    =DATEADD(DAY, 
											-1 * (DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 4, 30)) - 1), 
											DATEFROMPARTS(YEAR(@InputDate), 4, 30)),
				/* Last Sunday in October */
				DstEndDate      = DATEADD(DAY, 
											-1 * (DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 10, 31)) - 1), 
											DATEFROMPARTS(YEAR(@InputDate), 10, 31))
			WHERE @InputDate >= '19670101'
			  AND @InputDate <  '19840101'
			
			UNION ALL
			/* Before DST was a thing */
			SELECT 
				DstYear         = DATEPART(YEAR, @InputDate),
				DstStartDate    = NULL,
				DstEndDate      = NULL
			WHERE @InputDate <  '19670101'
		),
		EUR_DST AS (
			/* Current DST rules for EU since 1996*/
			SELECT 
				DstYear         = DATEPART(YEAR, @InputDate),
				/* Last Sunday in March */
				DstStartDate    = DATEADD(DAY, 
											-1 * (DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 3, 31)) - 1), 
											DATEFROMPARTS(YEAR(@InputDate), 3, 31)),
				/* Last Sunday in October */
				DstEndDate      = DATEADD(DAY, 
											-1 * (DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 10, 31)) - 1), 
											DATEFROMPARTS(YEAR(@InputDate), 10, 31))
			WHERE @InputDate >= '19960101'

			UNION ALL
			/* DST rules for Initial EU harmonization*/
			SELECT 
				DstYear         = DATEPART(YEAR, @InputDate),
				/* Last Sunday in March */
				DstStartDate    = DATEADD(DAY, 
											-1 * (DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 3, 31)) - 1), 
											DATEFROMPARTS(YEAR(@InputDate), 3, 31)),
				/* Last Sunday in September */
				DstEndDate      = DATEADD(DAY, 
											-1 * (DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 9, 30)) - 1), 
											DATEFROMPARTS(YEAR(@InputDate), 9, 30))
			WHERE @InputDate >= '19810101'
			  AND @InputDate <  '19960101'
			
			UNION ALL
			/* Before The EU was a thing */
			SELECT 
				DstYear         = DATEPART(YEAR, @InputDate),
				DstStartDate    = NULL,
				DstEndDate      = NULL
			WHERE @InputDate <  '19810101'
		),
		UK_DST AS (
			/* Current DST rules for UK since 2002*/
			SELECT 
				DstYear         = DATEPART(YEAR, @InputDate),
				/* Last Sunday in March */
				DstStartDate    = DATEADD(DAY, 
											-1 * (DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 3, 31)) - 1), 
											DATEFROMPARTS(YEAR(@InputDate), 3, 31)),
				/* Last Sunday in October */
				DstEndDate      = DATEADD(DAY, 
											-1 * (DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 10, 31)) - 1), 
											DATEFROMPARTS(YEAR(@InputDate), 10, 31))
			WHERE @InputDate >= '20020101'

			UNION ALL
			/* Legacy DST rules 1972-2001*/
			SELECT 
				DstYear         = DATEPART(YEAR, @InputDate),
				/* Third Sunday in March */
				DstStartDate    = DATEADD(DAY, 
											(21 - DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 3, 1)) + 1) % 7 + 14, 
											DATEFROMPARTS(YEAR(@InputDate), 3, 1)),
				/* Fourth Sunday in October */
				DstEndDate      = DATEADD(DAY, 
											(28 - DATEPART(WEEKDAY, DATEFROMPARTS(YEAR(@InputDate), 10, 1)) + 1) % 7 + 21, 
											DATEFROMPARTS(YEAR(@InputDate), 10, 1))
			WHERE @InputDate >= '19720101'
			  AND @InputDate <  '20020101'

			UNION ALL
			/* Permanent GMT+1 experiment*/
			SELECT 
				DstYear         = DATEPART(YEAR, @InputDate),
				/* Third Sunday in March */
				DstStartDate    = '19720101',
				/* Fourth Sunday in October */
				DstEndDate      = DATEADD(NANOSECOND, -1, '20020101')
			WHERE @InputDate >= '19720101'
			  AND @InputDate <  '20020101'
			
			UNION ALL
			/* Before The DST was a thing */
			SELECT 
				DstYear         = DATEPART(YEAR, @InputDate),
				DstStartDate    = NULL,
				DstEndDate      = NULL
			WHERE @InputDate <  '19681027'
		)
	SELECT * FROM USA_DST WHERE @Locality = 'USA'
	UNION ALL
	SELECT * FROM EUR_DST WHERE @Locality = 'EUR'
	UNION ALL
	SELECT * FROM UK_DST WHERE @Locality = 'UK'
);

GO

