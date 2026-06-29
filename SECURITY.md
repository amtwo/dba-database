# Security Policy

## Reporting a vulnerability

Found something that looks like a security problem? **Please don't open a public issue for it.** Email me privately at **andy@am2.co** instead, and give me a chance to sort it out before it's out in the open.

A few things that'd help when you write in:

* What the issue is and roughly how bad you think it is.
* Steps to reproduce it (the more specific, the better).
* The SQL Server version/edition and any setup details where you saw it.

I'll confirm I got your report, dig in, and keep you in the loop on a fix. I'll also happily credit you when it's resolved — unless you'd rather stay anonymous, in which case just say so.

## A little context

This is a collection of DBA utility scripts meant to run on servers *you* already administer, by someone who already has elevated permissions. A lot of it builds and runs dynamic SQL on purpose. So "security" here is mostly about not introducing surprises — SQL injection through an unguarded identifier, a script that does more than its header says, that kind of thing. If you spot one of those, I want to know.

## Supported versions

This is a personal toolbox, not enterprise software — I patch forward, on the current code in the `production` branch. If you're on an old release and hit something, the fix will land on the latest version, not as a backport.
