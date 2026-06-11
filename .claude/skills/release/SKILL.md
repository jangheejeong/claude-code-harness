---
name: release
description: "Wrap a reviewed Phase into a PR-ready state. Verifies the `Review: APPROVE` line in Plans.md, syncs docs via documenter, commits the docs, pushes the branch, opens a PR via `gh`. Does NOT push to main directly. Use after /review records APPROVE."
allowed-tools: Agent, Read, Edit, Write, Grep, Glob, Bash
disable-model-invocation: true
---

# /release — Ship the phase

The Phase's code is already committed on the work branch by `/work` (red/green checkpoints). `/release` adds the docs commit, pushes, and opens the PR.

## Steps

1. Verify the Phase is approved: `Plans.md` must contain the `Review: APPROVE — <date>` line that `/review` wrote for this Phase. If missing, route back to `/review`.
2. Spawn `@agent-documenter` (it reads the phase diff itself via the merge-base). Apply its doc edits.
3. Update `<subproject>/CHANGELOG.md` (Keep a Changelog format) — under `## [Unreleased]`. If no CHANGELOG exists, create one.
4. Mark the Phase done in `Plans.md` (check the Acceptance boxes the work actually satisfied).
5. Commit the docs:
   - `git add <explicit file list>` — only the doc edits + CHANGELOG + Plans.md. Never `git add -A`, never interactive flags (`-p`/`-i`).
   - Commit message: `docs(<scope>): phase <n> docs sync`.
6. Verify a clean tree: `git status --porcelain` must be empty. Leftovers mean drift — route back to `/work` or `/review`.
7. Push the branch (NOT to main): `git push -u origin <branch>`.
8. If `gh` is configured, open a PR:
   - Title: `<scope>: <phase title>`
   - Body: filled from Plan + Reviewer verdict + CHANGELOG entry.
   - Otherwise print the PR URL command for the user to run.

## Hard rules

- Never `git push --force` (hook will block).
- Never push to `main`/`master` directly.
- Never include changes outside the Phase's scope. If you find drift, route back to `/work` or `/review`.
