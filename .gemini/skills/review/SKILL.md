---
name: review
description: 4-lens review of the diff for the current Phase before merge. Spawns the reviewer subagent (opus) and prints a verdict. Use after /work, before any commit/push.
allowed-tools: Read Grep Glob Bash
---

# /review — Pre-merge gate

## Steps

1. Determine merge-base. Default: `git merge-base HEAD origin/main` (or `origin/master`, or whatever the project's main branch is). Ask if ambiguous.
2. Capture the diff: `git diff <merge-base>..HEAD`. Save to `.claude/notes/review-<phase>-<date>.diff` if it exceeds ~500 lines, then reference the file.
3. Read the relevant `Plans.md` Phase.
4. Spawn `@agent-reviewer` with: the Plan section, the diff (or pointer), and the merge-base.
5. Render the reviewer's verdict (APPROVE / REQUEST CHANGES / BLOCK) and findings.

## On BLOCK or REQUEST CHANGES

- Spawn `@agent-coder` with the findings.
- Re-run `/review` after the coder reports done.
- Loop max 3 cycles per Phase, then escalate.

## On APPROVE

- Suggest `/release` next.
- Do NOT auto-merge. Human merges.
