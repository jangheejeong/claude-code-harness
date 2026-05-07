---
name: release
description: Wrap a reviewed Phase into a PR-ready state. Updates CHANGELOG, syncs docs via documenter, optionally opens a PR via `gh`. Does NOT push to main directly. Use after /review approves.
allowed-tools: Read Edit Write Grep Glob Bash
disable-model-invocation: true
---

# /release — Ship the phase

## Steps

1. Verify the latest Phase is APPROVED (look at chat history or `Plans.md` checkboxes).
2. Spawn `@agent-documenter` with the merged diff. Apply its doc edits.
3. Update `<subproject>/CHANGELOG.md` (Keep a Changelog format) — under `## [Unreleased]`. If no CHANGELOG exists, create one.
4. Mark the Phase done in `Plans.md` (check the Acceptance boxes the work actually satisfied).
5. Commit:
   - `git add -p` style intent: only the Phase's files + docs + CHANGELOG.
   - Commit message: `<scope>: <phase title>` body referencing Plans.md phase id and any ADR added.
6. Push the branch (NOT to main):
   - `git push -u origin <branch>`
7. If `gh` is configured, open a PR:
   - Title: `<scope>: <phase title>`
   - Body: filled from Plan + Reviewer verdict + CHANGELOG entry.
   - Otherwise print the PR URL command for the user to run.

## Hard rules

- Never `git push --force` (hook will block).
- Never push to `main`/`master` directly.
- Never include changes outside the Phase's scope. If you find drift, route back to `/work` or `/review`.
