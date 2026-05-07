#!/usr/bin/env bash
# One-shot: clean .git, init fresh with PERSONAL credentials only,
# commit, create GitHub repo, push. Designed to leave NO trace of
# any work account.
#
# Usage:
#   PERSONAL_EMAIL="ID+jangheejeong@users.noreply.github.com" ./PUSH_TO_GITHUB.sh
#
# Personal noreply email lookup:
#   https://github.com/settings/emails  → "ID+username@users.noreply.github.com"

set -euo pipefail

REPO_NAME="claude-code-harness"
GH_OWNER="jangheejeong"
VISIBILITY="public"
PERSONAL_NAME="${PERSONAL_NAME:-jangheejeong}"
PERSONAL_EMAIL="${PERSONAL_EMAIL:-}"

cd "$(dirname "$0")"

# 1. Require PERSONAL_EMAIL
if [ -z "$PERSONAL_EMAIL" ]; then
  echo "ERROR: PERSONAL_EMAIL not set."
  echo
  echo "Look up your personal noreply email at:"
  echo "    https://github.com/settings/emails"
  echo "  (format: <id>+<username>@users.noreply.github.com)"
  echo
  echo "Then run:"
  echo "    PERSONAL_EMAIL='<your-email>' ./PUSH_TO_GITHUB.sh"
  exit 1
fi

# 2. Sanity: refuse to run if email looks like a work domain
case "$PERSONAL_EMAIL" in
  *@heumlabs.*|*@heum.*|*@neillab.*)
    echo "ERROR: $PERSONAL_EMAIL looks like a work email. Aborting."
    echo "  Use a personal address (recommend: noreply form from GitHub Settings → Emails)."
    exit 2
    ;;
esac

# 3. Sanity: directory looks right
if [ ! -f README.md ] || [ ! -d .claude ]; then
  echo "ERROR: run this script from inside the claude-code-harness directory."
  exit 1
fi

# 4. Wipe any prior .git (sandbox-broken or otherwise)
if [ -d .git ]; then
  echo "→ removing existing .git/"
  rm -rf .git
fi

# 5. Fresh init with PERSONAL credentials only — NEVER inherit from --global
echo "→ git init (personal credentials only)"
git init -b main
git config user.name  "$PERSONAL_NAME"
git config user.email "$PERSONAL_EMAIL"
echo "    user.name  = $(git config user.name)"
echo "    user.email = $(git config user.email)"

# 6. Make hooks/scripts executable
chmod +x .claude/hooks/*.sh scripts/harness/*.py 2>/dev/null || true

# 7. Stage + commit
echo "→ git add + commit"
git add -A
git commit -m "feat: initial harness — 6 subagents, 6 verb skills, 2 safety hooks

Plan → Work → Review → Release loop tuned for Python / Django /
FastAPI / Airflow projects on Claude Code v2.1+.

Components:
- agents: explorer, planner (opus), coder, tester, reviewer (opus), documenter
- skills: /plan, /work, /review, /release (locked), /setup, /orchestrator
- hooks: block-destructive, protect-secrets
- scripts: run_phase.py for context-isolated phase execution
- docs: REQUIREMENTS / ADR / DOC_SYNC_POLICY templates

Reviewer (opus) applies a 4-lens × 4-stack matrix with stack-specific
checks for Django ORM N+1, FastAPI async/sync mixing, Airflow
idempotency and DAG pitfalls, plus Pythonic patterns.

Findings tagged [BLOCK] / [CHANGES] / [NIT] / [EXISTING].

Hook tests: 18/18 destructive cases (false-positive 0), 11/11 secret cases."

# 8. Verify the commit author is personal
COMMIT_AUTHOR=$(git log -1 --pretty=format:'%an <%ae>')
echo "→ commit author: $COMMIT_AUTHOR"
case "$COMMIT_AUTHOR" in
  *@heumlabs.*|*@heum.*|*@neillab.*)
    echo "FATAL: commit author is a work email after configuration. Aborting."
    exit 3
    ;;
esac

# 9. Verify gh active account is personal
if command -v gh >/dev/null 2>&1; then
  ACTIVE_GH=$(gh auth status 2>&1 | grep -E 'Active account: true' -B 1 | grep 'Logged in to' | awk '{print $7}' | head -1)
  if [ -n "$ACTIVE_GH" ] && [ "$ACTIVE_GH" != "$GH_OWNER" ]; then
    echo "ERROR: gh active account is '$ACTIVE_GH', expected '$GH_OWNER'."
    echo "  Switch with: gh auth switch -u $GH_OWNER"
    echo "  (or add personal account: gh auth login)"
    exit 4
  fi
fi

# 10. Create remote and push
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo "→ gh repo create ${GH_OWNER}/${REPO_NAME} (${VISIBILITY})"
  if gh repo view "${GH_OWNER}/${REPO_NAME}" >/dev/null 2>&1; then
    echo "    repo already exists — adding remote and pushing"
    git remote add origin "https://github.com/${GH_OWNER}/${REPO_NAME}.git" 2>/dev/null || true
    git push -u origin main --force-with-lease
  else
    gh repo create "${GH_OWNER}/${REPO_NAME}" \
        --"${VISIBILITY}" \
        --source=. \
        --remote=origin \
        --description "Plan → Work → Review → Release harness for Claude Code v2.1+. Tuned for Python / Django / FastAPI / Airflow." \
        --push
  fi
else
  echo
  echo "→ gh CLI unavailable. Manual steps:"
  echo "    1. Create empty repo at https://github.com/new (Owner=${GH_OWNER}, Name=${REPO_NAME}, ${VISIBILITY})"
  echo "    2. git remote add origin https://github.com/${GH_OWNER}/${REPO_NAME}.git"
  echo "    3. git push -u origin main"
  exit 0
fi

echo
echo "✅ Done. View at: https://github.com/${GH_OWNER}/${REPO_NAME}"
echo
echo "Confirm contributor on GitHub:"
echo "  https://github.com/${GH_OWNER}/${REPO_NAME}/commits/main"
