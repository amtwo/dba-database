CREATE or ALTER FUNCTION dbo.GetDaylightSavingTimeDates (
                                            @Year INT, 
                                            @Locale varchar(3) = NULL)
RETURNS TABLE
AS
RETURN
(
    WITH DSTCalculation_USA AS
    (
        SELECT
            DSTYear  = @Year,
            Locale   = 'USA',
            -- Calculate the second Sunday in March
            DSTStart = DATEADD(DAY, 
                            (15 - DATEPART(weekday, DATEFROMPARTS(@Year, 3, 1))) % 7 + 7, 
                            DATEFROMPARTS(@Year, 3, 1)),
            -- Calculate the first Sunday in November
            DSTEnd   = DATEADD(DAY, 
                            (8 - DATEPART(weekday, DATEFROMPARTS(@Year, 11, 1))) % 7, 
                            DATEFROMPARTS(@Year, 11, 1))
    ), DSTCalculation_EU AS
    (SELECT
            DSTYear  = @Year,
            Locale   = 'EU',
            -- Calculate the last Sunday in March
            -- Finds the end of the month, then subtracts days to get to the preceding Sunday (assuming DATEFIRST 7)
            DSTStart = DATEADD(DAY, 
                            1 - DATEPART(weekday, EOMONTH(DATEFROMPARTS(@Year, 3, 1))), 
                            EOMONTH(DATEFROMPARTS(@Year, 3, 1))),
            -- Calculate the last Sunday in October
            DSTEnd   = DATEADD(DAY, 
                            1 - DATEPART(weekday, EOMONTH(DATEFROMPARTS(@Year, 10, 1))), 
                            EOMONTH(DATEFROMPARTS(@Year, 10, 1)))
    ), DSTCalculation_AUS AS
    (
        SELECT
            DSTYear  = @Year,
            Locale   = 'AUS',
            -- Calculate the first Sunday in October
            DSTStart = DATEADD(DAY, 
                            (8 - DATEPART(weekday, DATEFROMPARTS(@Year, 10, 1))) % 7, 
                            DATEFROMPARTS(@Year, 10, 1)),
            -- Calculate the first Sunday in April
            DSTEnd   = DATEADD(DAY, 
                            (8 - DATEPART(weekday, DATEFROMPARTS(@Year, 4, 1))) % 7, 
                            DATEFROMPARTS(@Year, 11, 1))
    ), DstDates AS (
        SELECT *
        FROM DSTCalculation_USA
        UNION ALL
        SELECT *
        FROM DSTCalculation_EU
        UNION ALL
        SELECT *
        FROM DSTCalculation_AUS
    )
    SELECT *
    FROM DstDates
    WHERE Locale = COALESCE(@Locale,Locale)
);
GO
