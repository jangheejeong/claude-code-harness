---
name: orchestrator
description: Run the full Plan->Work->Review->Release loop end-to-end with explicit checkpoints. Use only when the task is well-scoped and the user explicitly opts in (cost is ~5x a single skill). Stops at every approval gate by default.
---

# /orchestrator — Full loop

This is the end-to-end harness. It costs more tokens because it spawns multiple subagents in sequence; in return you get an auditable trail with checkpoints.

## Sequence (with stops)

```
/plan                            <- user approves Plans.md  -- STOP --
  v
for phase in Plans.md:
    /work <phase>                <- coder + tester             -- STOP optional --
    /review                      <- reviewer (opus)            -- STOP if not APPROVE --
    /release                     <- documenter + CHANGELOG + PR -- STOP --
```

## Defaults

- One Phase at a time. The user types `next` to advance, `pause` to stop, `parallel <N>` only on the user's explicit signal.
- `--auto` flag (off by default) skips the per-phase stop **only if** review verdict is APPROVE. Plan and final release stops are always present.
- A summary message is posted at every gate: completed Phase, diff size, verdict, next gate.

## Bash helper

For long runs, the orchestrator can shell out to `scripts/harness/run_phase.py` to keep main-context noise minimal:

```bash
python scripts/harness/run_phase.py --subproject api-server --phase 2 --agent coder
```

The script captures the subagent's output to `.claude/notes/phase-<n>-<agent>.log` and returns a one-line status to the main session.

## When NOT to use

- Quick one-file edits, doc tweaks, debugging where you need conversational back-and-forth — just talk to Claude directly.
- Exploration / spike work — no Plan exists yet by definition. Use `/plan` to escape the spike, but most spikes don't need the full orchestrator.
