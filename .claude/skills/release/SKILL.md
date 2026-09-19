---
name: release
description: Prepare an already reviewed change for commit, push, release notes, or a pull request. Use only after explicit user invocation and approval; do not implement unfinished work, bypass review, merge automatically, or publish outside the authorized scope.
disable-model-invocation: true
---

# Release

1. Verify the current change is the exact change approved by the reviewer and all required checks passed.
2. Update only documentation affected by verified behavior; use `documenter` when useful.
3. Stage only the approved files, then commit, push, or open a PR only within the user's explicit authorization.
4. Report the commit and PR. Merge requires separate authorization.
