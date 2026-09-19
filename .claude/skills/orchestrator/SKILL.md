---
name: orchestrator
description: Coordinate a non-trivial coding task from approved requirements through bounded implementation, optional testing, independent review, and release preparation. Use for “처음부터 끝까지”, multi-phase work, or follow-up fixes; do not use for a small edit, factual answer, or review-only request.
---

# Orchestrator

Use the lightest path that fits the change. Keep small work in the main conversation; use agents only for bounded work that benefits from isolated context.

1. Confirm an approved `Plans.md` or run `/plan`; never begin substantive code from unsettled requirements.
2. Give one phase to `coder`. Reuse that coder for fixes instead of making a new agent reread the same context.
3. Use `tester` only when behavior, risk, or missing coverage warrants an independent pass.
4. Ask one `reviewer` to perform the four-lens read-only review. Direct `/review` is one pass.
5. Own review retries here: count the first review as attempt 1, send evidence-backed findings to the same coder, then resume the same reviewer. Allow at most three total attempts.
6. Stop and hand off on `UNKNOWN`, an unchanged diff after a claimed fix, a repeated unresolved finding, or the third non-approval. On `APPROVE`, stop reviewing immediately.
7. Use `documenter` only when verified behavior affects documentation. Run `/release` only with explicit user authorization; never merge automatically.

Do not use lifecycle hooks, disk counters, external `claude -p` runners, or repeated broad checks to manage this flow.
