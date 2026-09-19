# Claude Code Harness

A lean personal harness for consistent planning, implementation, review, and release work without replacing Claude Code's native behavior.

## What it contains

- Six agents: `explorer`, `planner`, `coder`, `tester`, `reviewer`, and `documenter`
- Six skills: `/plan`, `/work`, `/review`, `/release`, `/setup`, and `/orchestrator`
- Two safety hooks: destructive-command blocking and secret-file write protection
- A conservative installer that links the canonical files globally and backs up only recognized legacy copies

There is no lifecycle hook loop, disk retry counter, external phase runner, agent announcement hook, or automatic post-edit lint. `/orchestrator` owns review retries inside the conversation.

## Recommended workflow

Let the main agent handle small edits directly. For non-trivial or risky changes, use:

```text
/plan → /work → /review → /release
```

- `/plan` records scope and acceptance criteria in `Plans.md`.
- `/work` implements one approved phase. A tester is optional.
- `/review` performs one independent pass across specification, security, correctness and maintainability, and performance and operations.
- `/release` prepares documentation, commits, pushes, or a PR only when explicitly invoked.
- `/orchestrator` coordinates the full flow and at most three review attempts, including the first review.

Automation stops when a finding repeats unchanged, the verdict is unclear, or the third review is not approved.

## Models and effort

| Role | Model | Effort |
|---|---|---|
| planner, reviewer | Opus | high |
| coder, tester | Sonnet | high |
| explorer | Sonnet | medium |
| documenter | Haiku | low |

Opus is reserved for high-consequence judgment, Sonnet handles implementation and verification, and lower effort is used where extra reasoning has limited value.

## Install

```bash
git clone https://github.com/jangheejeong/claude-code-harness.git
cd claude-code-harness
python3 scripts/install.py --workspace /Users/jangheejeong/Projects/heum
```

The installer creates repository-backed global links, preserves unmanaged files and settings, backs up only known legacy copies, removes retired harness hook registrations and `HARNESS_RUN_PHASE`, and leaves experimental agent-team settings untouched.

Preview changes first with:

```bash
python3 scripts/install.py --workspace /Users/jangheejeong/Projects/heum --dry-run
```

## Verify

```bash
python3 -m unittest discover -s tests -v
bash .claude/hooks/tests/run-tests.sh
```

Use `/skills` in a new Claude Code session to confirm discovery. Existing skill and agent directories are reloaded while Claude Code is running, but a new session is the most reliable way to verify hook configuration changes.

See [HARNESS.md](HARNESS.md) for operating rules and troubleshooting.

## Design references

- [Claude Code skills](https://code.claude.com/docs/en/skills)
- [Claude Code subagents](https://code.claude.com/docs/en/sub-agents)
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
