---
name: work
description: Execute one Phase from an approved Plans.md. Coder implements, then tester runs/extends tests. Use after /plan is approved. Stops at the Phase boundary so the user can decide to proceed or pause.
allowed-tools: Read Edit Write Grep Glob Bash
---

# /work — Phase execution

## Preconditions (HARD)

- An approved `Plans.md` exists in the target subproject. The user has checked off the Approval section.
- Working tree is clean OR on a dedicated branch / worktree (`.claude/worktrees/<feature>`).
- If you cannot verify both, refuse and route to `/plan` or to a branch creation step.

## Steps

1. **Read `<subproject>/Plans.md`**. Identify the next un-done Phase (or use the Phase number the user passed).
2. **Spawn `@agent-coder`** with the Phase id. Pass the file paths and Acceptance criteria from the Plan. Wait for the diff summary.
3. **Spawn `@agent-tester`** to verify and extend tests. If tester reports a coder bug, spawn coder again with the finding. Loop max 3 iterations, then escalate to user.
4. **Stop**. Print:
   - Phase number completed
   - Diff summary (files + LoC)
   - Test results
   - Suggested next step: `/review` (to gate) or `/work` again (next Phase) or pause

## Don't

- Don't run multiple Phases back-to-back without the user's signal. Cost and review-debt blow up.
- Don't commit, push, or open a PR. That's `/release`'s job.
- Don't introduce dependencies that aren't already in the project's lock file unless the Plan explicitly authorizes it.

## Optional flag — `parallel`

If the user types `/work --parallel <N>`, AND the Phase is internally decomposed into independent units, spawn N coder subagents in **isolated worktrees** (`isolation: worktree` in subagent frontmatter, or via `git worktree add`). Otherwise ignore the flag.
