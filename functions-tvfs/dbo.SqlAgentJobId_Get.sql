CREATE OR ALTER FUNCTION dbo.SqlAgentJobId_Get
(
    @ProgramName nvarchar(128)
)
RETURNS TABLE
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20261101
    Extracts and validates the hexadecimal SQL Agent job ID embedded in a session program name.

PARAMETERS
* @ProgramName - Session program name reported by SQL Server.

EXAMPLES:
SELECT *
FROM dbo.SqlAgentJobId_Get(N'SQLAgent - TSQL JobStep (Job 0x0123456789ABCDEF0123456789ABCDEF)');

**************************************************************************************************
MODIFICATIONS:
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
AS
RETURN
    SELECT
        JobIdHex = ProgramJob.JobIdHex,
        JobIdBinary = ParsedJobId.JobIdBinary,
        JobName = COALESCE(sysJob.name, N'Unknown Job')
    FROM (VALUES (
        CASE
            WHEN @ProgramName LIKE N'SQLAgent - TSQL JobStep (Job 0x%'
                THEN SUBSTRING(@ProgramName, 30, 34)
        END
    )) ProgramJob(JobIdHex)
    OUTER APPLY (VALUES (
        CASE
            WHEN LEN(ProgramJob.JobIdHex) = 34
             AND LEFT(ProgramJob.JobIdHex, 2) = N'0x'
                THEN TRY_CONVERT(binary(16), ProgramJob.JobIdHex, 1)
        END
    )) ParsedJobId(JobIdBinary)
    LEFT JOIN msdb.dbo.sysjobs sysJob
        ON CONVERT(binary(16), sysJob.job_id) = ParsedJobId.JobIdBinary;
GO
