# Contributing: Coding Style & Conventions

So you want to add something to the DBA database, or you're poking at the code and wondering why it looks the way it does. Cool. This doc is the house style.

A couple of things up front:

- **This is descriptive first, prescriptive second.** The rules here come from reading my actual code, not from a style guide I aspire to. Where the repo disagrees with itself (and it does — some of this code is from 2014), the **newer code wins**. I learn things; the old files just haven't caught up yet.
- **I lean hard on Aaron Bertrand's [Bad Habits & Best Practices](https://sqlblog.org/bad-habits) series.** A decade-plus of him explaining *why* certain T-SQL habits are bad so I don't have to. I'll link the relevant post wherever it backs up a rule. If you've never read the series, the links here are a pretty good crash course.

If you take one thing away: write it so the next person (often me, 18 months later, at 2am, on call) can read it.

---

## How to contribute

Quick heads-up on expectations: this is primarily *my* DBA toolbox (the README says as much). I'm happy to take contributions, but the bar is "would I run this on my own servers at 2am," so let's talk before you build.

1. **Open an issue first.** Describe the bug or the thing you want to add before you write a pile of code. Saves us both the heartbreak of a PR I can't take. [File one here.](https://github.com/amtwo/dba-database/issues/new/choose)
2. **Fork, then branch.** Don't work on `production` directly. Name the branch for what it does.
3. **Make it install cleanly.** Before you open the PR, run `Install-LatestDbaDatabase.ps1` against a real SQL Server instance (see the [README](README.md#to-install) for how). Then run it *again* — everything in this repo is idempotent, and a second install must succeed without errors. That's the closest thing to a test suite we've got, so it's the bar.
4. **Open the PR.** [CODEOWNERS](CODEOWNERS) routes review to me automatically. Tell me what you tested it against (version, edition) in the description.

There's no automated test harness. Verification is "run the object against a real instance and confirm it does what its header comment says it does." If you changed a proc, paste a before/after of the output in the PR — that's what sells it.

---

## The 30-second version

1. One object per file. Filename matches: `dbo.ObjectName.sql`.
2. New modules use `CREATE OR ALTER`. Always re-runnable.
3. Every module gets the header comment block. Fill it in.
4. **PascalCase** objects, columns, and parameters. Schema-qualify everything with `dbo.`.
5. Keywords UPPERCASE, **data types lowercase** (`int`, `sysname`, `nvarchar(max)`).
6. 4-space indent, spaces not tabs.
7. ANSI joins, no `SELECT *` in shipped code, alias columns with `=`.
8. Dynamic SQL goes through `sys.sp_executesql` with real parameters, never string-concatenated values.
9. `SET NOCOUNT ON;` at the top of every proc.

The rest of this doc is the *why*.

---

## File & repo layout

Objects live in folders by type, and that ordering isn't decorative — it's the install order the PowerShell installer walks (`Install-LatestDbaDatabase.ps1`):

```
tables/            → created first (everything else may depend on them)
Types/             → table types
views/
functions-scalar/
functions-tvfs/
stored-procedures/  → last
```

Rules:

- **One object per file.** No bundling three procs into one script because they're "related."
- **Filename = fully-qualified object name + `.sql`**: `dbo.Check_StatsDetails.sql`, `dbo.Dst_Dates.sql`. Schema prefix included, because the schema is part of the name.
- If a file is *only* a data seed or an index definition, say so in the name the way `dbo.CommandLog.Indexes.sql` does.

Why schema-qualify the filename (and everything else)? Because [leaving off the schema prefix is a bad habit](https://sqlblog.org/2019/09/12/bad-habits-to-kick-avoiding-the-schema-prefix) — it costs you a metadata lookup at runtime and it's ambiguous to the reader. Everything here is `dbo.`, on purpose, everywhere.

---

## How objects get created

**The standard for new code is `CREATE OR ALTER`.** It's clean, it's idempotent, and the whole repo targets versions that support it:

```sql
CREATE OR ALTER PROCEDURE dbo.Check_StatsDetails
    @DbName sysname,
    ...
AS
```

That's it. Re-running the script updates the object in place without dropping it.

### The legacy stub pattern (and the one case it survives)

A lot of the older files use a "stub then `ALTER`" dance:

```sql
IF NOT EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND object_id = object_id('dbo.Check_Blocking'))
    EXEC ('CREATE PROCEDURE dbo.Check_Blocking AS SELECT ''This is a stub''')
GO

ALTER PROCEDURE dbo.Check_Blocking
...
```

You'll see this everywhere in the back catalog. **Don't copy it into new files** — use `CREATE OR ALTER`. It's only still around for two reasons:

1. **History.** Those files predate `CREATE OR ALTER` being something I trusted to be everywhere.
2. **One legitimate exception:** the `sp_` procs that get installed into `master` and marked as system objects (see `dbo.sp_Get_BaseTableList.sql`). Dropping and recreating those would yank permissions and the system-object marking out from under anything using them, so the stub-then-`ALTER` approach stays. If you're not working in `master`, this doesn't apply to you.

**Everything must be idempotent.** Run the installer twice, get the same result. Tables use `IF NOT EXISTS` create plus conditional `ALTER`s; data seeds use `IF NOT EXISTS` guards (see `dbo.Config.sql`); modules use `CREATE OR ALTER`. No file should ever error because it was already run once.

---

## The header comment block

Every module (procs, functions, views) gets the flower box. It's not bureaucracy — it's the first thing anyone reads, and `dbo.Find_StringInModules` can grep it. Here's the current template:

```sql
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20260629
    Short description of what this thing does and, more importantly, why it exists.
    Two or three lines is plenty. Mention any policy/assumption that isn't obvious.

PARAMETERS
* @DbName - Target database name.
* @OnlySuspicious - Return only rows that may need action.

EXAMPLES:
-- The most common way you'd actually call this:
-- EXEC dbo.Check_StatsDetails @DbName = N'AMtwo';

**************************************************************************************************
MODIFICATIONS:
    20260629 - AM2 - What changed and why.
**************************************************************************************************
    This code is licensed as part of Andy Mallon's DBA Database.
    https://github.com/amtwo/dba-database/blob/master/LICENSE
    ©2014-2026 ● Andy Mallon ● am2.co
*************************************************************************************************/
```

Conventions inside the box:

- **`CREATED:` uses `YYYYMMDD`.** Unambiguous, sorts correctly, and sidesteps every regional date-format argument. Same reason I never use date shorthand in code — see [date/time shorthand](https://sqlblog.org/2011/09/20/bad-habits-to-kick-using-shorthand-with-date-time-operations).
- **`MODIFICATIONS:` is a running log**, newest entries appended, format `YYYYMMDD - AM2 - description`. Don't rewrite history; add a line.
- **`EXAMPLES:` should be real, runnable calls.** A future reader copy-pastes these. Make them work.
- Keep the description honest about *assumptions*. If a proc assumes the First Responder Kit is installed, or that you're sysadmin, say so.

---

## Naming

[Naming is the bikeshed of database design](https://sqlblog.org/2010/08/22/whats-in-a-name), so here's the ruling to end the argument. [Consistency beats cleverness](https://sqlblog.org/2009/10/11/bad-habits-to-kick-inconsistent-naming-conventions) every time.

### Objects

- **PascalCase**, with a **functional prefix** grouping by what the thing *does*: `Check_`, `Cleanup_`, `Set_`, `Get_`, `Find_`, `Repl_`, `Alert_`, `Agent_`. So: `Check_StatsDetails`, `Cleanup_BackupHistory`, `Set_AGReadOnlyRouting`, `Repl_AddArticle`.
- The prefix is the verb/category; the rest describes the target. Read it left to right like a sentence.
- **No dashes, no spaces, no reserved words** as names. [Don't make people bracket your identifiers](https://sqlblog.org/2009/10/09/bad-habits-to-kick-using-dashes-and-spaces-in-entity-names).

### The `sp_` exception

Most procs are *not* `sp_`-prefixed, and yours shouldn't be either. The handful that are (`dbo.sp_Get_BaseTableList`) are deliberately named that way because they get marked as system objects in `master` so they can run in the context of any database. That's the *only* reason to reach for `sp_`. If you don't have a specific reason rooted in that behavior, don't.

### Columns

PascalCase, descriptive, no Hungarian warts: `DatabaseName`, `SchemaName`, `RowCount_Alloc`, `SamplePercent`. A column name should tell you what it holds without a decoder ring.

### Parameters

**PascalCase, always:** `@DbName`, `@RowCountThreshold`, `@OnlySuspicious`, `@Debug`.

You'll spot two violations in the repo: the `Agent_Upsert_*` procs use `snake_case` (`@job_name`, `@notify_level_email`) because they mirror `msdb.dbo.sp_add_job` parameter-for-parameter, and the ancient `sp_Get_BaseTableList` uses lowercase. **Don't follow either.** New code is PascalCase even when it's wrapping a system proc — match the system proc's *behavior*, not its parameter casing. The `snake_case` in `Agent_Upsert` is a one-off I'd rather not repeat.

---

## Formatting

- **4 spaces, no tabs.** Some interim files slipped in tabs (`Dst_Dates`, the old `sp_` proc); the newest code is spaces and that's the standard.
- **Keywords UPPERCASE** (`SELECT`, `FROM`, `JOIN`, `CASE`, `WHERE`).
- **Data types lowercase** — see the next section, it's a real rule, not a vibe.
- **One column per line** in SELECT lists. It makes diffs readable and makes it obvious when someone adds or drops a column.
- **`JOIN` and its `ON` get their own lines**, with the `ON` indented under the join:

  ```sql
  FROM sys.stats AS s
  JOIN sys.objects AS o
      ON o.object_id = s.object_id
  JOIN sys.schemas AS sch
      ON sch.schema_id = o.schema_id
  ```

- **Align parameter blocks** so the types and defaults line up vertically. It's not pedantry — a misaligned default jumps out as a typo:

  ```sql
      @RowCountThreshold   bigint        = 10000000,    -- N rule: >= N rows uses sampled update
      @GiantSamplePercent  tinyint       = 50,          -- Sample percent when table is huge
      @OnlySuspicious      bit           = 0,           -- 1 = only rows that may need action
  ```

- **Terminate statements with semicolons.** They're not optional anymore in spirit, and several T-SQL features (CTEs, `THROW`, Service Broker) flat-out require them. Get in the habit.

---

## Data types

- **Lowercase data type names: `int`, `bigint`, `sysname`, `bit`, `decimal(5,2)`, `nvarchar(max)`.** This is the standard even though you'll find UPPERCASE in the `Agent_Upsert_*` procs — those mirror the casing in the `sp_add_job` docs, and that's the exception, not the rule. Default to lowercase.
- **Pick the right type for the data**, not whatever's handy. [Choosing the wrong data type](https://sqlblog.org/2009/10/12/bad-habits-to-kick-choosing-the-wrong-data-type) is a classic foot-gun. Use `sysname` for object names, `bit` for flags, `datetime2` over `datetime`, and size your decimals on purpose.
- **Always specify a length.** Never bare `varchar` / `nvarchar` — [an unspecified length doesn't mean "big," it means a silent 1 or 30 depending on context](https://sqlblog.org/2009/10/09/bad-habits-to-kick-declaring-varchar-without-length), and that's how you lose data.
- **Prefix Unicode literals with `N`:** `N'FULLSCAN'`, `N'SAMPLE 50 PERCENT'`. If the column is `nvarchar`, the literal should be too, or you get an implicit conversion you didn't ask for.

---

## Aliasing

- **Table aliases use `AS` and mean something.** `s` for `sys.stats`, `sp` for `sys.dm_db_stats_properties`, `sch` for schemas. Short is fine; [`a`, `b`, `c` / `t1`, `t2`, `t3` is not](https://sqlblog.org/2009/10/08/bad-habits-to-kick-using-table-aliases-like-a-b-c-or-t1-t2-t3). And [alias *every* table in a multi-table query or none of them](https://sqlblog.org/2010/02/16/bad-habits-to-kick-inconsistent-table-aliasing) — don't go halfway.
- **Column aliases use `=`, not `AS`:**

  ```sql
  SELECT
      DatabaseName  = DB_NAME(),
      SchemaName    = sch.name,
      SamplePercent = CONVERT(decimal(5,2), 100.0 * sp.rows_sampled / NULLIF(sp.[rows], 0))
  ```

  The alias is the first thing on the line, so you can read the output shape down the left margin. Aaron makes the [full case for `column = expression`](https://sqlblog.org/2012/01/23/bad-habits-to-kick-using-as-instead-of-for-column-aliases) better than I will here.

---

## Query habits

- **ANSI joins only.** `JOIN ... ON`, never the old `FROM a, b WHERE a.x = b.x` comma-join. [Old-style joins are a bad habit](https://sqlblog.org/2009/10/08/bad-habits-to-kick-using-old-style-joins) for a reason — and the old-style *outer* join syntax (`*=`) isn't even legal anymore.
- **No `SELECT *` in shipped code.** Name your columns. [Omitting the column list](https://sqlblog.org/2009/10/10/bad-habits-to-kick-using-select-omitting-the-column-list) breaks the moment someone adds a column, and it ships data you didn't mean to. (You'll catch a `SELECT *` in the *ad-hoc companion query* commented at the bottom of `Check_StatsDetails` — that's a throwaway I run by hand, not part of the shipped proc. Different rules for scratch work.)
- **`ORDER BY` real column names, never ordinals.** [`ORDER BY 2, 4` is a time bomb](https://sqlblog.org/2009/10/06/bad-habits-to-kick-order-by-ordinal) — it silently re-sorts the wrong way the instant the SELECT list changes.
- **Date ranges are half-open: `>= start AND < end`.** No `BETWEEN` on datetimes, no `<=` with a magic `23:59:59.997`. The repo does this consistently (`Dst_Dates` is wall-to-wall `>= '19960101' AND < '20070101'`), and it's the only approach that doesn't [mis-handle the boundary](https://sqlblog.org/2009/10/16/bad-habits-to-kick-mis-handling-date-range-queries).
- **Build dates, don't string them together.** `DATEFROMPARTS()` / `DATEADD()`, not string concatenation and not [date shorthand like `DATEADD(d, ...)`](https://sqlblog.org/2011/09/20/bad-habits-to-kick-using-shorthand-with-date-time-operations). And always use unambiguous literals — `'20260629'`, not `'06/29/2026'`.
- **Use `NULLIF` to dodge divide-by-zero** before it bites you, the way the stats math does: `100.0 * sp.rows_sampled / NULLIF(sp.[rows], 0)`.

---

## Dynamic SQL

A bunch of these tools build SQL on the fly to run across databases. When you do:

- **Use `sys.sp_executesql` with real parameters.** Pass values *as parameters*, don't concatenate them into the string. This is both safer and plan-cache-friendlier than [`EXEC(@sql)`](https://sqlblog.org/2011/09/17/bad-habits-to-kick-using-exec-instead-of-sp_executesql). `Check_StatsDetails` is the model: a fully-parameterized `sp_executesql` call with a typed parameter list. (Older files use `EXEC(@sql)` — that's legacy, don't copy it.)
- **`QUOTENAME()` every identifier** you splice into a string — database names, schema, object, index. It's how you survive a database named `[My DB; DROP...]` and assorted other surprises.
- **Give it a `@Debug` switch.** The convention is `@Debug bit = 0`, and when it's `1` the proc `PRINT`s the generated SQL and returns instead of running it. Look at how `Check_StatsDetails` even chunks the `PRINT` so long dynamic SQL doesn't get truncated at 4000 chars. If you write dynamic SQL, give me a way to see it without running it.

---

## Session settings & error handling

- **`SET NOCOUNT ON;` at the top of every proc.** Non-negotiable, it's in ~all of them. Stops the "(N rows affected)" chatter from confusing callers and clients.
- **Validate inputs early and bail loudly.** The pattern is a guard clause up top with `RAISERROR` and a `RETURN`:

  ```sql
  IF DB_ID(@DbName) IS NULL
  BEGIN
      RAISERROR('Database %s not found on this instance.', 16, 1, @DbName);
      RETURN;
  END;
  ```

  Tell the caller exactly what they did wrong. Don't let a bad parameter limp downstream into a confusing failure 80 lines later.
- **`SET XACT_ABORT ON;` is situational, not required.** You'll see it in the newest proc; use it when you're running multi-statement work that should roll back cleanly on error. It's a good default for anything transactional — just not something I'm forcing onto every read-only report.

---

## Cursors, loops, and "I'll just use a WHILE loop"

There are cursors in here, and there are `WHILE` loops, and both are fine *when the work is genuinely row-by-row* (iterating databases on an instance, walking a blocking chain). But don't reach for a loop to do something the set-based engine can do in one statement.

And know this going in: [a `WHILE` loop is still a cursor](https://sqlblog.org/2012/01/26/bad-habits-to-kick-thinking-a-while-loop-isnt-a-cursor), just one you built by hand and have to clean up yourself. Swapping `DECLARE CURSOR` for `WHILE @@FETCH_STATUS` doesn't magically make it set-based — if you're iterating, you're iterating. Make sure you actually need to.

---

## When the repo contradicts itself

It will. This code spans from 2014 to now, and I got better (and SQL Server got better) over that decade. When two files disagree:

1. **Newer wins.** Check the git history if you're unsure which is newer.
2. **This doc wins over both** — it's where I've written down the call.
3. **When in doubt, [don't just trust what you read](https://sqlblog.org/2012/02/27/bad-habits-to-kick-believing-everything-you-hear-or-read) — including me.** Test it. Open an issue or a PR and we'll talk it through.

For the full background on any of the linked habits above, the whole series is indexed at **<https://sqlblog.org/bad-habits>**. It's worth your time.

---

## Housekeeping

- **Be decent.** Participation here is covered by the [Code of Conduct](CODE_OF_CONDUCT.md). Read it.
- **Licensing.** Anything you contribute is licensed under the repo's existing [LICENSE](LICENSE) — by opening a PR, you're good with that.
- **The open-source bits aren't mine to relicense.** The First Responder Kit, Ola Hallengren's Maintenance Solution, sp_WhoIsActive, and Darling Data ship under their own licenses (the installer pulls them; I don't redistribute them). Don't send changes to *their* code here — send those upstream.
