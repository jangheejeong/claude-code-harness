---
name: work
description: Implement or continue one approved plan phase with a focused diff and proportional tests. Use for `/work` or an approved phase; do not use when requirements are unsettled, only review is requested, or release actions are needed.
---

# Work

1. Verify the target phase and acceptance criteria in `Plans.md`.
2. Ask `coder` to implement only that phase and run focused checks. Do not require red/green commits or push from the agent.
3. Use `tester` only for meaningful behavior, integration boundaries, regressions, or unverified edge cases.
4. Report the changed files, checks, and remaining risk. Stop at the phase boundary.

Standalone `/work` performs one phase and does not own review retries.
