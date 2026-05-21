---
name: orchestrator
description: Run the full Plan → Work (TDD) → Review → Release loop end-to-end with explicit human checkpoints. The default entry point of the harness. Stops at plan approval, BLOCK exhaustion, and PR merge.
---

# /orchestrator — Full loop (TDD by default)

End-to-end harness. The user types `/orchestrator <natural-language task>` once and the orchestrator runs the rest, stopping at three human gates: plan approval, BLOCK after 3 fix attempts, and PR merge.

## Sequence (with stops)

```
/plan                                         <- planner (Opus) writes Plans.md
                                              <- vertical slices, TDD-ready acceptance
                                              ⛔ STOP — user reviews + Approval ✓

for phase in Plans.md:
    /work <phase>                             <- coder runs TDD red-green-refactor
                                              <- tester verifies TDD + adds edge cases
                                              -- STOP optional --
    /review                                   <- reviewer (Opus) 4-lens
                                              <- if BLOCK → auto-fix loop max 3
                                              ⛔ STOP if loop exhausts
    /release                                  <- documenter + CHANGELOG + commit + push + gh pr create

⛔ STOP — user merges the PR on GitHub
```

## Defaults

- One Phase at a time. After each phase the orchestrator continues automatically through `/review` and `/release` (creating one PR per phase by default, or one cumulative PR if the user requests it).
- The user types `next` to advance to the next phase, `pause` to stop, `parallel <N>` only on explicit signal.
- `--auto` flag (off by default) skips the per-phase optional stop **only if** review verdict is APPROVE. Plan approval and final PR merge gates are always preserved.
- A summary is posted at every gate: completed Phase, TDD cycle summary, diff size, verdict, next gate.

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
