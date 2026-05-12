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
for h in block-destructive protect-secrets announce-agent; do
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

# Special handling: reviewer.md — 3-way auto-merge against cached previous upstream
# .claude/.harness-cache/upstream-prev/reviewer.md holds the upstream version that
# was current at the time of the *previous* update.sh run (= the merge ancestor).
# Strategy:
#   - First run (no cache)  → fall back to "preserve, do not overwrite" + seed cache
#   - Subsequent runs       → git merge-file <user> <cache> <new>
#                              clean   → file updated, no manual work
#                              conflict → marker-laden file + explicit warning
RV_CACHE_DIR=".claude/.harness-cache/upstream-prev"
RV_CACHE="$RV_CACHE_DIR/reviewer.md"
RV_USER=".claude/agents/reviewer.md"
RV_NEW="$TMP/harness/.claude/agents/reviewer.md"
RV_PLAN="skip"           # skip | seed | merge | nochange
RV_MSG=""

if [ -f "$RV_USER" ] && [ -f "$RV_NEW" ]; then
  if diff -q "$RV_NEW" "$RV_USER" >/dev/null 2>&1; then
    RV_PLAN="nochange"
  elif [ ! -f "$RV_CACHE" ]; then
    RV_PLAN="seed"
    RV_MSG="
⚠️  reviewer.md: first-time run — no merge ancestor cached.
    This run will NOT overwrite your reviewer.md (preserved).
    Cache seeded → future update.sh runs will auto-merge using git 3-way."
    echo "$RV_MSG"
  else
    RV_PLAN="merge"
    echo "  ↻ .claude/agents/reviewer.md  (will 3-way merge)"
  fi
fi

echo
echo "→ user files NOT touched (or auto-merged):"
echo "  · CLAUDE.md"
echo "  · .claude/settings*.json"
echo "  · .claude/agents/reviewer.md  ↻ 3-way auto-merge if cache exists"
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
for h in block-destructive protect-secrets announce-agent; do
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

# reviewer.md handling per RV_PLAN decided earlier
# Always keep the latest upstream as a side reference in backup
[ -f "$RV_NEW" ] && cp "$RV_NEW" "$BACKUP/reviewer.md.upstream-latest"

RV_RESULT=""
case "$RV_PLAN" in
  nochange)
    # user == new upstream; just refresh cache
    mkdir -p "$RV_CACHE_DIR"
    cp "$RV_NEW" "$RV_CACHE"
    ;;
  seed)
    # first run — preserve user file, seed cache for next time
    mkdir -p "$RV_CACHE_DIR"
    cp "$RV_NEW" "$RV_CACHE"
    RV_RESULT="seed"
    ;;
  merge)
    # 3-way merge: user file with cache as ancestor, new upstream as their version
    MERGED=$(mktemp)
    # git merge-file: --quiet suppresses conflict count; outputs to stdout with -p
    if git merge-file -p --quiet "$RV_USER" "$RV_CACHE" "$RV_NEW" > "$MERGED" 2>/dev/null; then
      cp "$MERGED" "$RV_USER"
      RV_RESULT="clean"
    else
      # conflict — file has <<<<<<< markers; still write it so user can resolve
      cp "$MERGED" "$RV_USER"
      RV_RESULT="conflict"
    fi
    rm -f "$MERGED"
    # Advance the cache pointer to the new upstream regardless of conflict outcome
    mkdir -p "$RV_CACHE_DIR"
    cp "$RV_NEW" "$RV_CACHE"
    ;;
esac

# Save examples/ as reference (always)
if [ -d "$TMP/harness/examples" ]; then
  mkdir -p examples
  cp -r "$TMP/harness/examples/"* examples/ 2>/dev/null || true
fi

echo
echo "✅ Done."
echo "   Backup of previous state: $BACKUP/"
case "$RV_RESULT" in
  clean)
    echo "   reviewer.md: 3-way merged cleanly with new upstream"
    ;;
  conflict)
    echo "   ⚠️  reviewer.md: 3-way merge produced CONFLICT MARKERS"
    echo "       File: $RV_USER  — open and resolve <<<<<<< / ======= / >>>>>>>"
    echo "       Upstream reference: $BACKUP/reviewer.md.upstream-latest"
    ;;
  seed)
    echo "   reviewer.md: first-time cache seeded (next update will auto-merge)"
    echo "       Upstream reference: $BACKUP/reviewer.md.upstream-latest"
    ;;
esac
echo "   Restart Claude Code to load updated agent/skill definitions:"
echo "     > /exit"
echo "     $ claude"
