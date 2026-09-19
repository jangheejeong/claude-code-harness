---
name: review
description: Run one independent four-lens review of a substantive working tree, commit, or pull request before release. Use for `/review`, audit, or inspection requests; do not implement fixes or recursively invoke review.
---

# Review

1. Resolve the approved plan, review base, and complete change set, including staged, unstaged, and in-scope untracked files.
2. Ask `reviewer` for one read-only pass in this order: spec correctness, security, correctness and maintainability, performance and operability.
3. Require evidence-backed findings with severity and `file:line`, distinguishing `[NEW]` from `[EXISTING]`.
4. Treat missing evidence or a malformed verdict as `UNKNOWN`, never approval.
5. Return the findings and verdict without editing code or invoking this skill again.

Only `/orchestrator` may send findings to a coder and request a bounded re-review.
