---
description: "Review phpbox for bugs, regressions, missing tests, terminal progress, and timeout gaps."
name: "Review phpbox project"
argument-hint: "Optional scope such as build, backup, service lifecycle, or whole project"
agent: "phpbox-reviewer"
---

Review the requested phpbox scope as a code review.

## Execution plan

1. Confirm the review scope and inspect the working tree without changing it.
2. Read the target, nearest caller, matching instructions, and nearest tests.
3. Trace the smallest failing path and identify the direct control point.
4. Review behavior, cleanup, rollback, exit codes, quoting, timeouts, progress output, and test coverage.
5. Report findings first by severity, then assumptions, residual risks, and a concise summary.

Do not edit files, run destructive Git commands, or claim a check passed unless it was executed.

Prioritize findings by severity and include clickable file paths. Check:

- incorrect behavior and regressions
- missing rollback or cleanup
- missing terminal stage/progress output
- missing timeout or no-response detection
- Bash quoting, set -u, pipeline, and exit-code errors
- Docker/Compose lifecycle and health-check failures
- backup/restore path handling
- tests that are missing or too weak

Remember that phpbox is a local development environment: passwords may be displayed openly for convenient lookup. Do not propose secret masking as a mandatory requirement.
