CREATE OR ALTER VIEW dbo.TimeZoneDetailed
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2020 ● Andy Mallon ● am2.co
*************************************************************************************************/
SELECT tz.TimeZoneId,
       tz.DisplayName,
       tz.StandardName,
       tz.DaylightName,
       tz.SupportsDaylightSavingTime,
       IsCurrentlyDst   = s.is_currently_dst,
       CurrentUtcOffset = s.current_utc_offset,
       CurrentName      = CASE
                            WHEN s.is_currently_dst = 1 THEN tz.DaylightName
                            ELSE tz.StandardName
                          END
FROM dbo.TimeZones tz
JOIN sys.time_zone_info s ON s.name = tz.TimeZoneId;
GO
