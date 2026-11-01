# Agent instructions

## Scope and safety

- Read [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md) before changing project code. The latter is the source of truth for T-SQL conventions; this file adds workflow and safety guidance.
- Keep changes focused. Do not reformat or modernize unrelated legacy SQL as part of a feature or fix.
- Treat installer scripts and SQL files as operational code: they can create or alter databases and server-level objects. Never run them against production or an instance outside an explicitly designated disposable or development scope. If no such instance is available, report that execution was not verified.
- Do not run `Get-OpenSourceScripts.ps1` as a validation step. It downloads mutable third-party code into `oss/`, which is intentionally ignored and is not part of this repository's tracked source.
- Preserve existing user changes. Inspect `git status` before editing and do not overwrite, stage, or discard unrelated work.

## Changes and validation

- Keep one database object per `.sql` file under the existing object-type folders. Preserve the install order documented in `CONTRIBUTING.md` and implemented by `Install-LatestDbaDatabase.ps1`.
- New T-SQL should follow the documented header, naming, formatting, idempotency, and safety conventions. Check dynamic SQL, permissions, transaction effects, and server/database scope carefully.
- For PowerShell changes, preserve the scripts' existing parameter and error-handling behavior unless the task calls for changing it.
- Use checks that do not connect to or modify a SQL Server when possible: inspect the diff, check whitespace, and use available static parsing/lint tools. Do not claim runtime behavior is verified without executing it in a suitable development environment.
- In your completion summary, identify changed files, checks performed, and any runtime checks that could not be performed.

## Contribution workflow

- Follow the issue-first and pull request process in [CONTRIBUTING.md](CONTRIBUTING.md). Do not create issues, comments, branches, or pull requests unless the user asks you to.
- Do not commit or push unless explicitly requested.
