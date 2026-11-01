<!--
Thanks for the PR! A few things that make it easy for me to say yes.
If you haven't already, skim CONTRIBUTING.md — especially the coding conventions.
-->

## What does this change?

<!-- A sentence or two. What's the proc/function/view, and what does it now do that it didn't? -->

## Related issue

<!-- Link the related issue when available. See CONTRIBUTING.md for the issue-first workflow. -->

## Coding agent & Review agent disclosure

* AI coding agents are allowed for code contributions.
* AI coding agents are **encouraged** for adversarial reviews prior to PR submission.

To help me evaluate your PR, please identify any agent used to write or modify code, including its provider, model, and reasoning effort when available. This information is context for review, not a measure of capability. Agents may not be able to fill this in themselves, humans can optionally complete the section; neither humans nor Agents should ever guess about answers.

### Coding agent details:
<!-- Summarize AI Agent(s) used for coding -->
* [ ] This PR was authored exclusively by humans

* **Coding agent(s), provider/model, and reasoning effort (if applicable):**
* [ ] Coding agent(s) used; details not included

### Adversarial review details
<!-- Summarize the adversarial review, identify whether it used a separate reviewer or a fresh self-review pass, and explain how actionable findings were handled. -->
* [ ] An AI Agent has not performed adversarial review on this PR

* **Adversarial review agent(s), provider/model, and reasoning effort (if applicable):**
* [ ] Adversarial review agent(s) used; details not included
* **Reviewer/review approach and summary:**
* **Findings resolved or left open (with reason):**
* [ ] Review had zero findings
* [ ] All findings were reconciled with high confidence

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
