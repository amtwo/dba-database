<!--
Thanks for the PR! A few things that make it easy for me to say yes.
If you haven't already, skim CONTRIBUTING.md — especially the coding conventions.
-->

## What does this change?

<!-- A sentence or two. What's the proc/function/view, and what does it now do that it didn't? -->

## Related issue

<!-- Link the related issue when available. See CONTRIBUTING.md for the issue-first workflow. -->

## Coding agent disclosure

AI coding agents are allowed for code contributions. To help me evaluate your PR, please identify any agent used to write or modify code, including its provider, model, and reasoning effort when available. This information is context for review, not a measure of capability. If a detail is not exposed, say so rather than guessing; if no AI coding agent was used, say so.

* **Coding agent(s), provider/model, and reasoning effort (if applicable):**

## Adversarial review

<!-- Summarize the adversarial review, identify whether it used a separate reviewer or a fresh self-review pass, and explain how actionable findings were handled. -->

Using an AI coding agent to perform an adversarial review of your PR is encouraged. To help me evaluate your PR, please identify any agent used for the adversarial review, including its provider, model, and reasoning effort when available. This information is context for review, not a measure of capability. If a detail is not exposed, say so rather than guessing; if no AI agent was used for the adversarial review, say so.

* **Adversarial review agent(s), provider/model, and reasoning effort (if applicable):**
* **Reviewer/review approach and summary:**
* **Findings resolved or left open (with reason):**

## How did you test it?

<!-- List checks that were actually performed; distinguish static checks from runtime testing. -->

* **Checks performed:**
* **SQL Server version / edition and isolated environment tested (if applicable):**
* **Runtime verification not performed / limitations (if applicable):**
* **Sample call and result (for behavior changes):**

```
-- paste the EXEC and what it returned here
```

## Checklist

* [ ] Follows the conventions in [CONTRIBUTING.md](../CONTRIBUTING.md) (naming, header comment block, `CREATE OR ALTER`, lowercase data types, etc.)
* [ ] One object per file, filename matches the object name
* [ ] The header comment block is filled in (description, parameters, examples, modifications)
* [ ] Re-running behavior was checked in an isolated development environment, or runtime verification is identified as not performed
