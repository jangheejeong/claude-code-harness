---
name: work
description: Execute one Phase from an approved Plans.md using strict TDD. Coder runs red-green-refactor cycle per acceptance bullet, then tester verifies TDD compliance and extends edge case coverage. Use after /plan is approved. Stops at the Phase boundary.
allowed-tools: Agent, Read, Edit, Write, Grep, Glob, Bash
---

# /work — Phase execution (TDD)

## Preconditions (HARD)

- An approved `Plans.md` exists in the target subproject. The user has checked off the Approval section.
- Working tree is clean OR on a dedicated branch / worktree (`.claude/worktrees/<feature>`).
- Each Phase in `Plans.md` has TDD-ready acceptance criteria (testable, observable). If criteria are vague, route back to `/plan` instead of guessing.
- If you cannot verify the above, refuse and route to `/plan` or to a branch creation step.

## Steps

1. **Read `<subproject>/Plans.md`**. Identify the next un-done Phase (or use the Phase number the user passed). Quote its acceptance criteria back at the top of your message.

2. **Branch guard**. Check `git branch --show-current`. If on `main`/`master`, create a work branch BEFORE spawning coder — respect the user's branch conventions (e.g. Jira ticket id); default `phase/<n>-<slug>`. Coder commits land on this branch.

3. **Spawn `@agent-coder`** with the Phase id. Coder follows strict TDD per acceptance bullet, committing each checkpoint on the work branch:
   - RED: write the failing test first; run it; confirm failure; commit `test(<scope>): red — <bullet summary>`
   - GREEN: minimal implementation to pass; commit `feat(<scope>): green — <bullet summary>` (or `fix`/`refactor` type)
   - REFACTOR: only if needed, while keeping tests green
   
   Coder never pushes, never amends/rebases existing commits, never commits secrets. Wait for the diff summary with per-cycle RED/GREEN notes.

4. **Spawn `@agent-tester`** to:
   - Verify the coder followed TDD discipline — git history is the evidence: each acceptance bullet's red commit precedes its green commit
   - Map every acceptance bullet to ≥1 test
   - Add edge case tests beyond the bullets (empty/null, boundary values, concurrency, error paths, time, encoding) — tester may commit them as `test(<scope>): edge cases — phase <n>`
   
   If tester reports a TDD violation or production bug, spawn coder again with the finding. Loop max 3 iterations, then escalate to user.

5. **Stop**. Print:
   - Phase number completed
   - Diff summary (files + LoC)
   - TDD cycle summary (per acceptance bullet)
   - Tester's edge cases added
   - Test run results
   - Suggested next step: `/review` (to gate) or `/work` again (next Phase) or pause

## Don't

- Don't accept "test-after" from coder. If coder skipped RED verification, escalate.
- Don't run multiple Phases back-to-back without the user's signal.
- Don't push or open a PR — commits stay local on the work branch; push/PR is `/release`'s job. Never amend or rebase existing commits.
- Don't introduce dependencies that aren't already in the project's lock file unless the Plan explicitly authorizes it.

## Optional flag — `parallel`

If the user types `/work --parallel <N>`, AND the Phase is internally decomposed into independent vertical sub-slices, spawn N coder subagents in **isolated worktrees** — create them via Bash: `git worktree add .claude/worktrees/<slice> -b phase/<n>-<slice>`. Each subagent still follows strict TDD inside its slice. Otherwise ignore the flag.
