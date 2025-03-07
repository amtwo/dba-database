IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'IF' AND object_id = object_id('dbo.AgentJobHistory_TimeConvert'))
    EXEC ('CREATE FUNCTION dbo.AgentJobHistory_TimeConvert() RETURNS TABLE AS RETURN SELECT Result = ''This is a stub'';' )
GO

ALTER FUNCTION dbo.AgentJobHistory_TimeConvert (@Date int, @Time int, @Duration int)
RETURNS TABLE
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20250307
    SQL Agent stores times & durations like it's 1982, using only integer datatypes.
    Intended to take in values from sysjobhistory & convert things to datetime2(0)
PARAMETERS:
    @Date - Accepts run_date values (an integer date in the format yyyyMMDD )
    @Time - Accepts run_time values (an integer time in the format hh24mmss )
    @Duration - Accepts run_duration (an integer with a cyptic formula)
EXAMPLES:
* SELECT j.name, h.step_id, h.message, t.* 
  FROM msdb.dbo.sysjobs j 
  JOIN msdb.dbo.sysjobhistory h ON h.job_id = j.job_id
  CROSS APPLY dbo.AgentJobHistory_TimeConvert (h.run_date, h.run_time, h.run_duration) t
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2025 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
RETURN

    WITH TimeMath AS (
        SELECT DATETIMEFROMPARTS(@Date / 10000, -- years
                    @Date % 10000 / 100, -- months
                    @Date % 100, -- days
                    @Time / 10000, -- hours
                    @Time % 10000 / 100, -- minutes
                    @Time % 100, -- seconds
                    0 -- milliseconds
                ) AS RunStartDateTime,
                (@Duration / 10000) * 3600 -- convert hours to seconds, can be greater than 24
                + ((@Duration % 10000) / 100) * 60 -- convert minutes to seconds
                + (@Duration % 100) AS RunDurationSeconds
        )
    SELECT RunStartDateTime   = RunStartDateTime,
           RunFinishDateTime  = DATEADD(SECOND,RunDurationSeconds,RunStartDateTime),
           RunDurationSeconds = RunDurationSeconds
    FROM TimeMath;
GO

