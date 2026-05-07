#!/usr/bin/env bash
# update.sh — pull latest claude-code-harness assets into the current project.
#
# Safe to re-run. Preserves user-customized files:
#   - CLAUDE.md
#   - .claude/settings*.json
#   - .claude/agents/reviewer.md        (stack-specific customization expected)
#   - .claude/notes/, worktrees/, agent-memory*/
#   - <subproject>/REQUIREMENTS.md, Plans.md
#
# Overwrites (managed harness assets):
#   - .claude/agents/{coder,tester,planner,explorer,documenter}.md
#   - .claude/skills/*/SKILL.md
#   - .claude/hooks/*.sh
#   - scripts/harness/run_phase.py
#   - docs/harness/*.md
#   - HARNESS.md
#
# Usage:
#   bash update.sh                              # interactive
#   bash update.sh --yes                        # skip confirmation
#   bash update.sh --branch <name>              # use non-default branch

set -euo pipefail

REPO="https://github.com/jangheejeong/claude-code-harness.git"
BRANCH="main"
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=true; shift ;;
    --branch) BRANCH="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# 0. Sanity — must be in a project that already has .claude/ (i.e., harness was installed before)
if [ ! -d .claude ]; then
  echo "ERROR: no .claude/ directory in $(pwd)."
  echo "       Run this from the project where the harness is installed."
  echo "       For first-time install, follow the README's Install section instead."
  exit 1
fi

# 1. Clone latest to temp dir
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

echo "→ cloning $REPO ($BRANCH) → $TMP"
git clone --quiet --depth 1 --branch "$BRANCH" "$REPO" "$TMP/harness"

# 2. Show what will change
echo
echo "→ inspecting differences"

# Function: report diff for one file (overwrite candidate)
report_diff() {
  local src="$1" dst="$2" label="$3"
  if [ ! -f "$dst" ]; then
    echo "  + $label  (new file)"
  elif ! diff -q "$src" "$dst" >/dev/null 2>&1; then
    local lines=$(diff "$dst" "$src" | wc -l | tr -d ' ')
    echo "  ~ $label  ($lines lines changed)"
  fi
}

# Standard agent files (overwrite, but reviewer.md is special)
for a in coder tester planner explorer documenter; do
  report_diff "$TMP/harness/.claude/agents/$a.md" ".claude/agents/$a.md" ".claude/agents/$a.md"
done

# Skills
for s in plan work review release setup orchestrator; do
  if [ -f "$TMP/harness/.claude/skills/$s/SKILL.md" ]; then
    report_diff "$TMP/harness/.claude/skills/$s/SKILL.md" ".claude/skills/$s/SKILL.md" ".claude/skills/$s/SKILL.md"
  fi
done

# Hooks
for h in block-destructive protect-secrets; do
  report_diff "$TMP/harness/.claude/hooks/$h.sh" ".claude/hooks/$h.sh" ".claude/hooks/$h.sh"
done

# Phase runner
[ -f "$TMP/harness/scripts/harness/run_phase.py" ] && \
  report_diff "$TMP/harness/scripts/harness/run_phase.py" "scripts/harness/run_phase.py" "scripts/harness/run_phase.py"

# Doc templates
for d in REQUIREMENTS.template.md ADR.template.md DOC_SYNC_POLICY.md; do
  [ -f "$TMP/harness/docs/harness/$d" ] && \
    report_diff "$TMP/harness/docs/harness/$d" "docs/harness/$d" "docs/harness/$d"
done

# Top-level docs
[ -f "$TMP/harness/HARNESS.md" ] && \
  report_diff "$TMP/harness/HARNESS.md" "HARNESS.md" "HARNESS.md"

# Special handling: reviewer.md
RV_MSG=""
if [ -f .claude/agents/reviewer.md ]; then
  if ! diff -q "$TMP/harness/.claude/agents/reviewer.md" .claude/agents/reviewer.md >/dev/null 2>&1; then
    RV_MSG="
⚠️  .claude/agents/reviewer.md is different upstream.
    This file is expected to be customized per stack.
    The script will NOT overwrite it. Backup will be saved if you want to inspect."
    echo "$RV_MSG"
  fi
fi

echo
echo "→ user files NOT touched:"
echo "  · CLAUDE.md"
echo "  · .claude/settings*.json"
echo "  · .claude/agents/reviewer.md"
echo "  · .claude/notes/, worktrees/, agent-memory*/"
echo "  · <subproject>/REQUIREMENTS.md, Plans.md"

# 3. Confirm
if [ "$ASSUME_YES" = false ]; then
  echo
  read -r -p "Proceed with update? [y/N] " ans
  case "$ans" in
    y|Y) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# 4. Backup whole .claude/agents and .claude/skills and .claude/hooks before overwrite
TS=$(date +%Y%m%d-%H%M%S)
BACKUP=".claude/.harness-backup-$TS"
echo
echo "→ backup → $BACKUP/"
mkdir -p "$BACKUP"
[ -d .claude/agents ] && cp -r .claude/agents "$BACKUP/agents"
[ -d .claude/skills ] && cp -r .claude/skills "$BACKUP/skills"
[ -d .claude/hooks  ] && cp -r .claude/hooks  "$BACKUP/hooks"
[ -d scripts/harness ] && mkdir -p "$BACKUP/scripts" && cp -r scripts/harness "$BACKUP/scripts/"
[ -d docs/harness   ] && mkdir -p "$BACKUP/docs"    && cp -r docs/harness    "$BACKUP/docs/"
[ -f HARNESS.md     ] && cp HARNESS.md "$BACKUP/HARNESS.md"

# 5. Apply updates (selective)
echo "→ updating managed files"

mkdir -p .claude/agents .claude/skills .claude/hooks scripts/harness docs/harness

# Standard agents (NOT reviewer)
for a in coder tester planner explorer documenter; do
  cp "$TMP/harness/.claude/agents/$a.md" ".claude/agents/$a.md"
done

# Skills
for s in plan work review release setup orchestrator; do
  if [ -d "$TMP/harness/.claude/skills/$s" ]; then
    rm -rf ".claude/skills/$s"
    cp -r "$TMP/harness/.claude/skills/$s" ".claude/skills/$s"
  fi
done

# Hooks
for h in block-destructive protect-secrets; do
  cp "$TMP/harness/.claude/hooks/$h.sh" ".claude/hooks/$h.sh"
  chmod +x ".claude/hooks/$h.sh"
done

# Phase runner
[ -f "$TMP/harness/scripts/harness/run_phase.py" ] && {
  cp "$TMP/harness/scripts/harness/run_phase.py" "scripts/harness/run_phase.py"
  chmod +x "scripts/harness/run_phase.py"
}

# Doc templates
for d in REQUIREMENTS.template.md ADR.template.md DOC_SYNC_POLICY.md; do
  [ -f "$TMP/harness/docs/harness/$d" ] && cp "$TMP/harness/docs/harness/$d" "docs/harness/$d"
done

# HARNESS.md
[ -f "$TMP/harness/HARNESS.md" ] && cp "$TMP/harness/HARNESS.md" HARNESS.md

# Save the latest reviewer.md as a side reference (don't overwrite user's)
if [ -f "$TMP/harness/.claude/agents/reviewer.md" ]; then
  cp "$TMP/harness/.claude/agents/reviewer.md" "$BACKUP/reviewer.md.upstream-latest"
fi

# Save examples/ as reference (always)
if [ -d "$TMP/harness/examples" ]; then
  mkdir -p examples
  cp -r "$TMP/harness/examples/"* examples/ 2>/dev/null || true
fi

echo
echo "✅ Done."
echo "   Backup of previous state: $BACKUP/"
[ -n "$RV_MSG" ] && echo "   Latest upstream reviewer.md: $BACKUP/reviewer.md.upstream-latest"
echo "   Restart Claude Code to load updated agent/skill definitions:"
echo "     > /exit"
echo "     $ claude"
