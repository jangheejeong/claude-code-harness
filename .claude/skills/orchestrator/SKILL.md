---
name: orchestrator
description: Run the full Plan → Work (TDD) → Review → Release loop end-to-end with explicit human checkpoints. The default entry point of the harness — use when the user wants a feature taken from idea to PR ("처음부터 끝까지", "run the whole flow", 3+ phases of work). Stops at plan approval, each review verdict, fix-loop exhaustion, and PR merge.
---

# /orchestrator — Full loop (TDD by default)

End-to-end harness. The user types `/orchestrator <natural-language task>` once and the orchestrator runs the rest, stopping at three hard gates — plan approval, the fix loop ending without an APPROVE (3 attempts spent, or stalled on an unchanged working tree), PR merge — plus a per-phase optional stop after each review verdict.

## Sequence (with stops)

```
/plan                                         <- planner (Fable) writes Plans.md
                                              <- vertical slices, TDD-ready acceptance
                                              ⛔ STOP — user reviews + Approval ✓

for phase in Plans.md:
    /work <phase>                             <- branch guard (never on main/master)
                                              <- coder TDD per bullet: red commit → green commit
                                              <- tester verifies TDD via git history + adds edge cases
    /review                                   <- reviewer (Fable) 4-lens on the phase diff
                                              <- BLOCK or REQUEST CHANGES → auto-fix loop max 3
                                              ⛔ STOP if loop exhausts or stalls
                                              <- APPROVE → `Review: APPROVE` line in Plans.md
                                              -- STOP optional (skipped by --auto on APPROVE) --
    release steps (inline)                    <- documenter → CHANGELOG → docs commit → push → gh pr create

⛔ STOP — user merges the PR on GitHub
```

## Defaults

- One Phase at a time. `/work` flows directly into `/review` — no stop in between.
- The per-phase optional stop sits **after** the `/review` verdict: post the gate summary and wait for the user. `next` runs the release steps and starts the next phase, `pause` stops, `parallel <N>` only on explicit signal.
- On BLOCK or REQUEST CHANGES the auto-fix loop runs: spawn coder with the findings, re-run `/review` — 3 cycles, then ⛔ STOP. The count is not yours to keep: `.claude/hooks/record-verdict.sh` records every reviewer verdict in `.claude/notes/loop-state.json` and `.claude/hooks/enforce-loop.sh` reads it at the end of each main turn — while budget remains **and the working tree has moved since the last cycle** it exits 2 and refuses to let the turn end, and once the budget is spent it lets the turn end with a message saying this is not success and a human is needed. Reviewer subagents must be named `reviewer` or `reviewer-*`, or none of this fires.
- **Budget left and the hook still exits 0** — read the stderr before assuming it passed. `무진전 중단` means the working tree fingerprints identically to the previous cycle: the coder's round reached no file, so the hook spends none of the remaining attempts. That is a stop, not a pass. Do not run another cycle and do not report success; ⛔ STOP and hand the findings to the user, the same as on exhaustion.
- `/release` is user-invocable only (`disable-model-invocation: true` hides it from the model entirely), so the orchestrator does NOT invoke the skill. Instead it performs the same steps INLINE, following `.claude/skills/release/SKILL.md`: verify `Review: APPROVE` in Plans.md → documenter → CHANGELOG → Plans.md checkboxes → `docs(<scope>): phase <n> docs sync` commit → clean-tree check (`git status --porcelain` empty) → push → `gh pr create`. One PR per phase by default, or one cumulative PR if the user requests it.
- `--auto` flag (off by default) skips the per-phase optional stop **only if** the review verdict is APPROVE. Plan approval and final PR merge gates are always preserved.
- A summary is posted at every gate: completed Phase, TDD commit trail (red → green), diff size, verdict, next gate.

## Bash helper

For long runs the orchestrator can shell out to `scripts/harness/run_phase.py` to keep main-context noise minimal:

```bash
python scripts/harness/run_phase.py --subproject api-server --phase 2 --agent coder
```

The script captures the subagent's output to `.claude/notes/phase-<n>-<agent>-<ts>.log` and returns a one-line status to the main session.

## When NOT to use

- Quick one-file edits, doc tweaks, debugging where conversational back-and-forth is more useful than structured phases — talk to Claude directly.
- Exploration / spike work — no Plan exists yet by definition.
- Tasks under ~3 phases of work — the harness overhead exceeds the benefit.
