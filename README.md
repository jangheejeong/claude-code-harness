# claude-code-harness

> A pragmatic Plan → Work → Review → Release harness for **Claude Code v2.1+**, tuned for Python / Django / FastAPI / Airflow projects.

[![Claude Code](https://img.shields.io/badge/Claude_Code-v2.1+-purple)](https://code.claude.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
**English** | [한국어](README.ko.md)

---


## What this is

A drop-in `.claude/` configuration that turns Claude Code into a disciplined development partner:

- **6 subagents** (explorer, planner, coder, tester, reviewer, documenter) — each runs in its own context window so verbose output doesn't pollute your main session.
- **6 verb skills** (`/plan`, `/work`, `/review`, `/release`, `/setup`, `/orchestrator`) — explicit workflow steps with required gates.
- **2 safety hooks** — block destructive shell commands (`rm -rf /`, `git push --force`, `git reset --hard origin/*`) and refuse to write secrets (`.env`, `*.pem`, `credentials.json`, `.mcp.json`) at the system level.
- **Phase runner script** — `scripts/harness/run_phase.py` keeps long phase work out of your main context window.
- **Doc templates** — `REQUIREMENTS.md`, `ADR-NNN.md`, `DOC_SYNC_POLICY.md`.

## Why a harness

Claude Code is powerful but undisciplined out of the box. This harness enforces:

1. **Plan-first** — no code change without a phased `Plans.md` with measurable acceptance criteria.
2. **Phase boundaries** — one reviewable unit at a time (≤400 LoC diff target).
3. **4-lens review** — spec correctness, security, correctness/maintainability, performance — with stack-specific checks for Django ORM N+1, FastAPI async/sync mixing, Airflow idempotency, etc.
4. **Hooks over hopes** — destructive commands blocked by deterministic shell scripts, not by trusting the model.
5. **Human gates** — the user still approves the plan, reviews the verdict, and merges the PR. The harness **reduces** human work, doesn't eliminate it.

This is not "AI does it all". It's "AI does the expensive parts, human handles the gates."

## Install

### Quick (existing project)

```bash
cd ~/your-project
git clone https://github.com/jangheejeong/claude-code-harness.git .claude-code-harness-tmp
cp -r .claude-code-harness-tmp/.claude ./
cp -r .claude-code-harness-tmp/scripts ./
cp -r .claude-code-harness-tmp/docs ./
cp .claude-code-harness-tmp/CLAUDE.md.example ./CLAUDE.md     # then edit
cp .claude-code-harness-tmp/HARNESS.md ./
rm -rf .claude-code-harness-tmp

# Make hooks executable
chmod +x .claude/hooks/*.sh

# Wire hooks into settings (or merge with your existing settings.local.json)
cat > .claude/settings.json <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/block-destructive.sh" }]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/protect-secrets.sh" }]
      }
    ]
  }
}
JSON
```

Then start `claude`, run `/agents` to confirm the 6 agents loaded, run `/` to confirm the 6 verb skills.

### Per-subproject (monorepo / multi-repo workspace)

If your `~/projects/foo/` contains multiple independent git repos and you want one harness controlling all of them:

1. Drop `.claude/`, `scripts/`, `docs/`, `CLAUDE.md`, `HARNESS.md` at the workspace root.
2. Edit the `CLAUDE.md` to list your subprojects.
3. Run `claude` from the workspace root — Claude Code will pick up the harness for any subproject within it.

## Usage (30-second flow)

```
$ cd ~/your-project && claude

> add HMAC verification to the webhook handler. /plan let's go
   ⛔ STOP — review the generated Plans.md, check the Approval boxes

> /work 1
   ⛔ STOP — eyeball the diff

> /review
   ⛔ STOP — check verdict

> /release   # ← must type yourself, auto-invocation is locked
   ⛔ STOP — merge the PR on GitHub

> /work 2 ... repeat
```

For short tasks, skip the harness entirely:
```
> just change the log level to INFO in apps/server.py
```

## What's where

```
.
├── CLAUDE.md.example         # template — copy to CLAUDE.md and customize
├── HARNESS.md                # full user guide (the doc to read)
├── .claude/
│   ├── agents/               # 6 subagent definitions
│   ├── skills/               # 6 verb skills
│   └── hooks/                # 2 safety hooks
├── scripts/harness/
│   └── run_phase.py          # context-isolated phase runner
└── docs/harness/
    ├── REQUIREMENTS.template.md
    ├── ADR.template.md
    └── DOC_SYNC_POLICY.md
```

Read [HARNESS.md](HARNESS.md) for the comprehensive guide (12 sections + cheat sheet + troubleshooting).

## Stack-specific reviewer

The `reviewer` agent (Opus) applies a 4-lens × 4-stack matrix:

| Lens | General | Django | FastAPI | Airflow |
|---|---|---|---|---|
| **Security** | secrets, PII logging | raw SQL f-string, mark_safe XSS | `Depends` auth, `response_model` leakage | BashOperator injection, plaintext Connections |
| **Correctness** | comprehensions, mutable defaults, EAFP, `with` | `save()` override, signals, migration reversibility | async-sync mixing, Pydantic v1↔v2 | idempotency, top-level imports, `xcom` payload size, Jinja templates |
| **Performance** | generators | **N+1** (`select_related`/`prefetch_related`), `bulk_*`, `.exists()` vs `len()` | unbounded queries, sync logging in async | dynamic task mapping, sensor reschedule mode, pool/priority |

Findings are tagged `[BLOCK]` / `[CHANGES]` / `[NIT]` / `[EXISTING]` (the last one for pre-existing bugs that don't block this PR).

## Safety hooks — what they block

```
# block-destructive.sh tested on 18 cases:
✓ blocks: rm -rf /, ~, $HOME, /usr/*, /etc/*, /Library/*, ...
✓ blocks: git push --force, --force-with-lease, -f
✓ blocks: git reset --hard origin/<branch>
✓ blocks: dd of=/dev/sd*
✓ allows: rm -rf node_modules, /tmp/foo, .venv (false positive: 0)
✓ allows: git push -u origin feat/x

# protect-secrets.sh tested on 11 cases:
✓ blocks: .env*, *.pem, *.key, credentials.json, tokens.yaml, .mcp.json
✓ allows: README.md, main.py, credentials.md (doc files)
```

## Honest limitations

- **"No developer needed" is marketing.** Plan approval, BLOCK verdicts, and PR merges are still human decisions.
- **Plan quality determines everything.** A weak Plan produces weak code, weak tests, and a weak review. Spend Opus tokens on the planner.
- **Cost matters.** A full `/orchestrator` run costs ~5-6× a single chat. Phase your work small, or skip the harness for trivial changes.
- **Multi-repo refactors** are not the harness's strength. One repo at a time.

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgments

- Workflow shape inspired by 민세홍's 6-agent design for the heum monorepo.
- Best-practice references: [Chachamaru127/claude-code-harness](https://github.com/Chachamaru127/claude-code-harness), [Anthropic Claude Code docs](https://code.claude.com/docs).
