---
description: "Run the phpbox pre-release validation checklist with visible progress and bounded operations."
name: "Validate phpbox release"
argument-hint: "Optional release scope or service version"
agent: "agent"
---

Run a pre-release validation for phpbox.

## Execution plan

1. Print a start stage and record the requested release scope.
2. Inspect `git status --short`; do not modify or discard existing changes.
3. Print a stage, then run Bash syntax checks for `install.sh`, `bin/phpbox`, and `lib/*.sh`.
4. Print a stage, then run repository lint and behavior tests when present.
5. Print a stage, then validate generated or sample Compose configuration when Docker is available, with a timeout.
6. Print a stage, then inspect long network, build, archive, and health-check operations for timeout or no-response protection.
7. Report every check as `PASS`, `FAIL`, or `SKIPPED` with the command and reason.
8. End with blockers, residual risks, and the exact next action; do not modify files unless explicitly requested.
