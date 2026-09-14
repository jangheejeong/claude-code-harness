---
name: review
description: 4-lens review of the current Phase's diff (commits on the work branch). Spawns the reviewer subagent (fable), prints a verdict, records APPROVE in Plans.md. Use after /work, before /release (push/PR).
allowed-tools: Agent, Read, Edit, Grep, Glob, Bash
---

# /review — Pre-merge gate

## Steps

1. Determine the base branch — the branch this work branch was created from. Default `origin/main`, fall back to `main`. Ask if ambiguous.
2. Capture the diff to review. `last_reviewed_head` in `.claude/notes/loop-state.json` decides which of two:

   - **Absent** (round 1, or a phase that just started) → the whole phase: `git diff $(git merge-base <base-branch> HEAD)...HEAD`
   - **Present** (round 2+) → only what the coder touched since the round that filed the findings: `git diff <last_reviewed_head>`

   `.claude/hooks/record-verdict.sh` writes that key at each reviewer stop and drops it on APPROVE, so a new phase always starts from a full diff. You do not maintain it.

   Plain `git diff <sha>`, **not** `<sha>..HEAD` — the plain form includes the working tree, so a coder who fixed things without committing shows up as work rather than as an empty diff.

   Check the base is still there first: `git cat-file -e <last_reviewed_head>^{commit}`. If it fails, the coder amended or rebased — fall back to the full phase diff and **say so when you spawn the reviewer**. A base that quietly resolves to nothing hands the reviewer an empty diff and buys an APPROVE for code nobody read.

   An empty incremental diff against a base that *is* reachable is not "nothing to review" — it is no progress. Stop and escalate with the previous round's findings, the same conclusion `.claude/hooks/enforce-loop.sh` reaches on an unmoved fingerprint.

   Save to `.claude/notes/review-<phase>-<date>.diff` if it exceeds ~500 lines, then reference the file. Keep the earlier rounds' files — step 5 hands them over.
3. Run `git status --porcelain`. Any uncommitted or untracked leftovers are themselves a `[NEW][CHANGES]` finding ("work not committed") — pass them along to the reviewer.
4. Read the relevant `Plans.md` Phase.
5. Spawn `@agent-reviewer` with: the Plan section, the diff (or pointer), the merge-base, and any step-3 leftovers. If you name the subagent, the name must start with `reviewer` — `.claude/hooks/record-verdict.sh` records a verdict only for `reviewer` and `reviewer-*`, and any other name silently switches the loop budget below off.

   On round 2+, hand over three things, not one: the incremental diff, **the previous round's full-phase diff file path**, and **the previous round's findings**. The incremental diff is where the reviewer starts, not the limit of what it may judge — spec correctness is still decided against the whole Phase, and the reviewer has `Read`/`Grep`/`Bash` to reach any part of it. Withhold the full diff and the round-2 reviewer can only tell you the fixes look fine, which is not the question.
6. Render the reviewer's verdict (APPROVE / REQUEST CHANGES / BLOCK) and findings.

## On BLOCK or REQUEST CHANGES

- Spawn `@agent-coder` with the findings (fix mode).
- Re-run `/review` after the coder reports done.
- The budget is 3 cycles per Phase, and **you are not the one counting them**. `.claude/hooks/record-verdict.sh` writes each reviewer verdict and the attempt number to `.claude/notes/loop-state.json`, and `.claude/hooks/enforce-loop.sh` reads that file at the end of every main turn:
  - budget left **and the working tree moved since the last cycle** → the hook exits 2, which refuses to end the turn and puts the re-dispatch instruction on stderr. The turn after a fresh BLOCK does not end on your say-so.
  - budget left **but the working tree fingerprints identically to the previous cycle** → the hook exits 0, with attempts still on the counter, and prints `무진전 중단` on stderr. That is a stop, not a pass. It does not mean the hook died or the phase passed; it means the coder's cycle reached no file, so another one buys the same review of the same code. Do not start it — escalate to the user with the findings.
  - budget spent (attempt 3) → the hook lets the turn end and prints that this is **not** success and a human has to take it from here. Escalate, do not start a fourth cycle.
  - `[enforce-loop] 리뷰어 판정이 기록되지 않았습니다: …` on a turn that exits 0 → a reviewer ran and its verdict never reached disk, so that cycle was never counted. Not something a coder can fix: report it and let the user check the hooks.

## On APPROVE

- Append a verdict line under the Phase in `Plans.md`: `Review: APPROVE — <YYYY-MM-DD>`. This is the durable artifact `/release` checks.
- Suggest `/release` next.
- Do NOT auto-merge. Human merges.
