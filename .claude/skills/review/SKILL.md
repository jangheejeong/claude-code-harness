---
name: review
description: 4-lens review of the current Phase's diff (commits on the work branch). Spawns the reviewer subagent (fable), prints a verdict, records APPROVE in Plans.md. Use after /work, before /release (push/PR).
allowed-tools: Agent, Read, Edit, Grep, Glob, Bash
---

# /review — Pre-merge gate

## Steps

1. Determine the base branch — the branch this work branch was created from. Default `origin/main`, fall back to `main`. Ask if ambiguous.
2. Capture the phase diff: `git diff $(git merge-base <base-branch> HEAD)...HEAD`. Save to `.claude/notes/review-<phase>-<date>.diff` if it exceeds ~500 lines, then reference the file.
3. Run `git status --porcelain`. Any uncommitted or untracked leftovers are themselves a `[NEW][CHANGES]` finding ("work not committed") — pass them along to the reviewer.
4. Read the relevant `Plans.md` Phase.
5. Spawn `@agent-reviewer` with: the Plan section, the diff (or pointer), the merge-base, and any step-3 leftovers. If you name the subagent, the name must start with `reviewer` — `.claude/hooks/record-verdict.sh` records a verdict only for `reviewer` and `reviewer-*`, and any other name silently switches the loop budget below off.
6. Render the reviewer's verdict (APPROVE / REQUEST CHANGES / BLOCK) and findings.

## On BLOCK or REQUEST CHANGES

- Spawn `@agent-coder` with the findings (fix mode).
- Re-run `/review` after the coder reports done.
- The budget is 3 cycles per Phase, and **you are not the one counting them**. `.claude/hooks/record-verdict.sh` writes each reviewer verdict and the attempt number to `.claude/notes/loop-state.json`, and `.claude/hooks/enforce-loop.sh` reads that file at the end of every main turn:
  - budget left → the hook exits 2, which refuses to end the turn and puts the re-dispatch instruction on stderr. Ending the turn on a BLOCK is not something you can decide to do.
  - budget spent (attempt 3) → the hook lets the turn end and prints that this is **not** success and a human has to take it from here. Escalate, do not start a fourth cycle.

## On APPROVE

- Append a verdict line under the Phase in `Plans.md`: `Review: APPROVE — <YYYY-MM-DD>`. This is the durable artifact `/release` checks.
- Suggest `/release` next.
- Do NOT auto-merge. Human merges.
