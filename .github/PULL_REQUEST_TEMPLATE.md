<!--
Thanks for the PR! A few things that make it easy for me to say yes.
If you haven't already, skim CONTRIBUTING.md — especially the coding conventions.
-->

## What does this change?

<!-- A sentence or two. What's the proc/function/view, and what does it now do that it didn't? -->

## Related issue

<!-- Link the issue you opened first. "Closes #123". If there isn't one, why not? (See CONTRIBUTING.md — issue-first is the norm here.) -->

## How did you test it?

<!-- There's no automated test suite, so this is what sells the PR. -->

* **SQL Server version / edition tested against:**
* **Installed cleanly via `Install-LatestDbaDatabase.ps1` (and a second time, to confirm it's idempotent):** [ ] yes
* **Before/after output, or a sample call + result:**

```
-- paste the EXEC and what it returned here
```

## Checklist

* [ ] Follows the conventions in [CONTRIBUTING.md](../CONTRIBUTING.md) (naming, header comment block, `CREATE OR ALTER`, lowercase data types, etc.)
* [ ] One object per file, filename matches the object name
* [ ] The header comment block is filled in (description, parameters, examples, modifications)
* [ ] Re-running the script is safe (idempotent)
