CREATE OR ALTER PROCEDURE dbo.QueryStore_GuardrailState
    @DatabaseName sysname,
    @QueryHashes  nvarchar(max) = NULL,
    @ActiveDays   int           = 3,
    @Debug        bit           = 0
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
DESCRIPTION
    Reports Query Store hints and forced plans across query text variants. Guardrails apply to a
    query_id, so a changed statement can create a new, unguarded variant while the old variant
    retains its hint or forced plan. The report identifies orphaned guardrails and generates
    statements to copy a sibling hint or matching forced plan. It never applies those changes.
    Requires Query Store hint support, available in SQL Server 2022 and later.

PARAMETERS
* @DatabaseName - Target database name. The database must have Query Store enabled.
* @QueryHashes - Comma-separated query_hash values in 0x hex form. NULL returns hashes with at
  least one hinted or forced variant.
* @ActiveDays - Number of days used to identify recently active variants and orphaned guardrails.
* @Debug - Print the assembled dynamic SQL.

EXAMPLES:
-- Report all query hashes that currently have a hint or forced plan:
-- EXEC dbo.QueryStore_GuardrailState @DatabaseName = N'AMtwo';

-- Inspect one statement hash and treat variants inactive for seven days as orphaned:
-- EXEC dbo.QueryStore_GuardrailState
--     @DatabaseName = N'AMtwo',
--     @QueryHashes = N'0x0123456789ABCDEF',
--     @ActiveDays = 7;
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @DatabaseName)
BEGIN
    RAISERROR('Database %s does not exist.', 16, 1, @DatabaseName);
    RETURN;
END;

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @DatabaseName AND is_query_store_on = 1)
BEGIN
    RAISERROR('Database %s does not have Query Store on.', 16, 1, @DatabaseName);
    RETURN;
END;

DECLARE @SupportsQueryStoreHints bit = 0,
        @VersionCheck nvarchar(400) = QUOTENAME(@DatabaseName) + N'.sys.sp_executesql';

EXEC @VersionCheck
    N'SELECT @SupportsQueryStoreHints = CASE WHEN OBJECT_ID(N''sys.query_store_query_hints'') IS NULL THEN 0 ELSE 1 END;',
    N'@SupportsQueryStoreHints bit OUTPUT',
    @SupportsQueryStoreHints = @SupportsQueryStoreHints OUTPUT;

IF @SupportsQueryStoreHints = 0
BEGIN
    RAISERROR('Database %s does not expose Query Store hints. This report requires Query Store hint support, available in SQL Server 2022 and later.', 16, 1, @DatabaseName);
    RETURN;
END;

DECLARE @Exec nvarchar(400) = QUOTENAME(@DatabaseName) + N'.sys.sp_executesql',
        @UtilityDatabase sysname = DB_NAME(),
        @Sql  nvarchar(max);

/* Parse the list here, in dba's context: STRING_SPLIT needs compat 130+, and the target database
   may be lower. The dynamic SQL below runs in a child scope, so it can read this temp table. */
CREATE TABLE #Hashes
(
    query_hash binary(8) NOT NULL PRIMARY KEY
);

IF @QueryHashes IS NOT NULL
    INSERT #Hashes (query_hash)
    SELECT DISTINCT CONVERT(binary(8), LTRIM(RTRIM(ss.value)), 1)
    FROM STRING_SPLIT(@QueryHashes, N',') AS ss
    WHERE LTRIM(RTRIM(ss.value)) <> N'';

SET @Sql = N'
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT 1000;

DECLARE @ActiveSince datetimeoffset(7) = DATEADD(DAY, -@ActiveDays, SYSDATETIMEOFFSET());

IF @QueryHashes IS NULL
    INSERT #Hashes (query_hash)
    SELECT DISTINCT q.query_hash
    FROM sys.query_store_query AS q
    WHERE EXISTS (SELECT 1 FROM sys.query_store_query_hints AS h WHERE h.query_id = q.query_id)
       OR EXISTS (SELECT 1 FROM sys.query_store_plan AS p WHERE p.query_id = q.query_id AND p.is_forced_plan = 1);

CREATE TABLE #Variants
(
    query_id            bigint            NOT NULL PRIMARY KEY,
    query_hash          binary(8)         NOT NULL,
    object_id           bigint            NOT NULL,
    initial_compile     datetimeoffset(7) NULL,
    last_execution_time datetimeoffset(7) NULL,
    HintText            nvarchar(max)     NULL,
    HintFailures        bigint            NULL,
    ForcedPlanId        bigint            NULL,
    ForcedPlanHash      binary(8)         NULL,
    ForceFailures       bigint            NULL
);

INSERT #Variants (query_id, query_hash, object_id, initial_compile, last_execution_time,
                  HintText, HintFailures, ForcedPlanId, ForcedPlanHash, ForceFailures)
SELECT
    q.query_id,
    q.query_hash,
    q.object_id,
    q.initial_compile_start_time,
    q.last_execution_time,
    h.query_hint_text,
    h.query_hint_failure_count,
    fp.plan_id,
    fp.query_plan_hash,
    fp.force_failure_count
FROM #Hashes AS hs
JOIN sys.query_store_query AS q
    ON q.query_hash = hs.query_hash
LEFT JOIN sys.query_store_query_hints AS h
    ON h.query_id = q.query_id
OUTER APPLY (
    SELECT TOP (1) p.plan_id, p.query_plan_hash, p.force_failure_count
    FROM sys.query_store_plan AS p
    WHERE p.query_id = q.query_id
      AND p.is_forced_plan = 1
) AS fp
WHERE q.last_execution_time >= @ActiveSince
   OR h.query_id IS NOT NULL
   OR fp.plan_id IS NOT NULL;

SELECT
    v.query_hash,
    v.query_id,
    ObjectName       = OBJECT_SCHEMA_NAME(v.object_id) + N''.'' + OBJECT_NAME(v.object_id),
    InitialCompile   = v.initial_compile,
    LastExecution    = v.last_execution_time,
    Guardrail        = COALESCE(N''HINT '' + v.HintText, N''FORCED '' + CONVERT(nvarchar(20), v.ForcedPlanHash, 1)),
    v.HintFailures,
    v.ForcedPlanId,
    v.ForceFailures,
    QuickieStoreCommand = N''EXEC '' + QUOTENAME(@UtilityDatabase) + N''.dbo.sp_QuickieStore @database_name = N'' + NCHAR(39)
        + REPLACE(@DatabaseName, NCHAR(39), NCHAR(39) + NCHAR(39)) + NCHAR(39)
        + N'', @include_query_ids = N'' + NCHAR(39) + CONVERT(nvarchar(20), v.query_id) + NCHAR(39)
        + N'', @start_date = N'' + NCHAR(39) + N''1753-01-01T00:00:00+00:00'' + NCHAR(39)
        + N'', @expert_mode = 1;'',
    IsOrphaned       = CASE WHEN (v.HintText IS NOT NULL OR v.ForcedPlanId IS NOT NULL)
                             AND (v.last_execution_time IS NULL OR v.last_execution_time < @ActiveSince)
                            THEN 1 ELSE 0 END,
    FixSql           = CASE
                           WHEN v.HintText IS NOT NULL OR v.ForcedPlanId IS NOT NULL THEN NULL
                           WHEN sh.HintText IS NOT NULL
                               THEN N''EXEC sys.sp_query_store_set_hints @query_id = '' + CONVERT(nvarchar(20), v.query_id)
                                    + N'', @query_hints = N'''''' + REPLACE(sh.HintText, N'''''''', N'''''''''''') + N'''''';''
                           WHEN sp.plan_id IS NOT NULL
                               THEN N''EXEC sys.sp_query_store_force_plan @query_id = '' + CONVERT(nvarchar(20), v.query_id)
                                    + N'', @plan_id = '' + CONVERT(nvarchar(20), sp.plan_id) + N'';''
                       END
FROM #Variants AS v
OUTER APPLY (   -- newest hinted sibling
    SELECT TOP (1) s.HintText
    FROM #Variants AS s
    WHERE s.query_hash = v.query_hash
      AND s.query_id <> v.query_id
      AND s.HintText IS NOT NULL
    ORDER BY s.last_execution_time DESC
) AS sh
OUTER APPLY (   -- a sibling''s forced plan shape that also exists under this variant
    SELECT TOP (1) p.plan_id
    FROM #Variants AS s
    JOIN sys.query_store_plan AS p
        ON p.query_id = v.query_id
       AND p.query_plan_hash = s.ForcedPlanHash
    WHERE s.query_hash = v.query_hash
      AND s.query_id <> v.query_id
      AND s.ForcedPlanId IS NOT NULL
    ORDER BY s.last_execution_time DESC
) AS sp
ORDER BY v.query_hash, v.last_execution_time DESC;';

IF @Debug = 1
    PRINT @Sql;

DECLARE @PreviousLockTimeout int = @@LOCK_TIMEOUT;
BEGIN TRY
    EXEC @Exec @Sql,
        N'@DatabaseName sysname, @UtilityDatabase sysname, @QueryHashes nvarchar(max), @ActiveDays int',
        @DatabaseName = @DatabaseName,
        @UtilityDatabase = @UtilityDatabase,
        @QueryHashes = @QueryHashes,
        @ActiveDays  = @ActiveDays;
END TRY
BEGIN CATCH
    SET LOCK_TIMEOUT @PreviousLockTimeout;
    THROW;
END CATCH;
SET LOCK_TIMEOUT @PreviousLockTimeout;
GO
