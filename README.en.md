# claude-code-harness

> A pragmatic Plan → Work → Review → Release harness for **Claude Code v2.1+**. **Stack-agnostic by default — fill in your own stack-specific rules.**

[![Claude Code](https://img.shields.io/badge/Claude_Code-v2.1+-purple)](https://code.claude.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[한국어](README.md) | **English**

---


## What this is

A drop-in `.claude/` configuration that turns Claude Code into a disciplined development partner:

- **6 subagents** (explorer, planner, coder, tester, reviewer, documenter) — each runs in its own context window so verbose output doesn't pollute your main session.
- **6 verb skills** (`/plan`, `/work`, `/review`, `/release`, `/setup`, `/orchestrator`) — explicit workflow steps with required gates.
- **2 safety hooks** — block destructive shell commands (`rm -rf /`, `git push --force`, `git reset --hard origin/*`) and refuse to write secrets (`.env`, `*.pem`, `credentials.json`, `.mcp.json`) at the system level.
- **Phase runner script** — `scripts/harness/run_phase.py` keeps long phase work out of your main context window.
- **Doc templates** — `REQUIREMENTS.md`, `ADR-NNN.md`, `DOC_SYNC_POLICY.md`.

## Why a harness — in plain words

Claude Code is powerful but undisciplined out of the box. This harness enforces 5 things:

### 1. Plan-first — "no nailing without a blueprint"
When you say "add this feature," Claude does NOT start typing code. It first writes a `Plans.md` design doc breaking the work into Phases with measurable acceptance criteria. **Only after you check the boxes does coding start.** Stops the AI from drifting off course.

### 2. Phase boundary — "one bite at a time"
A Phase is one reviewable unit (~400 LoC diff target). Don't ship one giant feature in one PR. **A 1000-line PR is too big for humans to review properly, and bugs slip through.**

### 3. 4-lens review — "review with 4 different glasses"
Before merge, the reviewer agent looks from 4 angles:
- **spec**: did the diff actually meet what the Plan said
- **security**: secrets, missing auth, injection
- **correctness**: edge cases, error handling, naming
- **performance**: slow paths, memory blowups

Plus stack-specific checks. Example: Django's classic N+1 (looping over a queryset and accessing `.user.email` triggers 100 DB hits).

### 4. Hooks over hopes — "block dangerous things in code, not in prompts"
Instead of *asking* the model "please don't `rm -rf /`," a shell script intercepts the command before it runs and blocks it. **The model can forget, the script can't.**

### 5. Human gates — "the AI doesn't do it all"
Plan approval, BLOCK verdict decisions, PR merging — these 3 stay human. **You can't fall asleep and let the AI ship to production.**

---

Net effect: "AI handles the expensive parts (writing code, mapping tests to acceptance, 4-angle review), human handles the gates."


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

## Reviewer — Stack-Agnostic by Default

The `reviewer` agent (Opus) applies a 4-lens review:

| Lens | Universal checks |
|---|---|
| **Spec** | Acceptance bullet ↔ code line mapping |
| **Security** | secrets, PII logging, injection (SQL/command/template), SSRF, path traversal, AuthZ |
| **Correctness** | edge cases, error handling, naming, dead code, test coverage |
| **Performance** | memory blowup, blocking I/O, logging / tracing / metrics |

**Stack-specific rules are intentionally empty placeholders** — fill them in for your stack. See next section.


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

## Customize for Your Stack

This harness is intentionally **language- and framework-agnostic** out of the box. Fill in your stack as follows.

### What to edit, where

| What you want to customize | File to edit | How / reference |
|---|---|---|
| **Stack-specific review rules** (ORM N+1, async/sync mixing, migration safety, framework pitfalls) | `.claude/agents/reviewer.md` — the "Stack-specific" subsections | Use `examples/reviewer-python.md` (Python+Django+FastAPI+Airflow) or `examples/reviewer-java-spring.md` (Java+Spring+JPA+WebFlux) as a starting point |
| **Dependency manager / lint / type-check / test runner names** | `.claude/agents/coder.md`, `tester.md` | Already generic — Coder/Tester auto-detect from your project's `pyproject.toml`/`package.json`/`pom.xml`. Override only if you want to enforce a specific tool. |
| **Build artifact dirs to skip** | `.claude/agents/explorer.md` skip list | `target/`, `build/`, `dist/`, `node_modules/`, `.venv/` already included. Add project-specific dirs as you find them. |
| **Test directory layout** | `.claude/agents/tester.md` | Auto-inferred (`tests/`, `src/test/java/`, `__tests__/`). Override only if non-standard. |
| **Project map / always-on rules** | `CLAUDE.md` | Copy from `CLAUDE.md.example` and fill in for your project. |
| **Requirements / acceptance criteria per subproject** | `<subproject>/REQUIREMENTS.md` | Copy from `docs/harness/REQUIREMENTS.template.md`. |

### Full reference reviewers (copy → modify)

| Stack | File |
|---|---|
| Python (Django / FastAPI / Airflow) | [`examples/reviewer-python.md`](examples/reviewer-python.md) |
| Java (Spring Boot / JPA / WebFlux) | [`examples/reviewer-java-spring.md`](examples/reviewer-java-spring.md) |
| _Kotlin / Scala / Go / Rust / Ruby / ..._ | (PRs welcome) |

Copy command:
```bash
cp examples/reviewer-<your-stack>.md .claude/agents/reviewer.md
```

### 30-Minute Stack-ification Checklist

1. **Reviewer**: copy your stack's example to `.claude/agents/reviewer.md`. If your stack isn't covered, fill in the 4 lens × stack-specific subsections yourself.
2. **CLAUDE.md**: copy `CLAUDE.md.example` and fill in your project map and rules.
3. **REQUIREMENTS**: for new subprojects, copy `docs/harness/REQUIREMENTS.template.md` to `<subproject>/REQUIREMENTS.md`. The `/setup` skill automates this.
4. **Restart `claude`** → `/plan` for your first feature.

The other agents (planner, coder, tester, explorer, documenter) are all stack-agnostic. No edits needed.


## License

MIT. See [LICENSE](LICENSE).

## Acknowledgments

- Workflow shape inspired by 민세홍's 6-agent design for the heum monorepo.
- Best-practice references: [Chachamaru127/claude-code-harness](https://github.com/Chachamaru127/claude-code-harness), [Anthropic Claude Code docs](https://code.claude.com/docs).
