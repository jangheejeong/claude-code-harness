#!/usr/bin/env bash
# update.sh — pull latest claude-code-harness assets into the current project.
#
# Safe to re-run. Preserves user-customized files:
#   - GEMINI.md
#   - .gemini/settings*.json
#   - .gemini/agents/reviewer.md        (stack-specific customization expected)#   - .gemini/notes/, worktrees/
#   - <subproject>/REQUIREMENTS.md, Plans.md
#
# Overwrites (managed harness assets):
#   - .gemini/agents/{coder,tester,planner,explorer,documenter}.md
#   - .gemini/skills/*/SKILL.md
#   - .gemini/hooks/*.sh
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
BRANCH="google"
ASSUME_YES=false
 
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=true; shift ;;
    --branch) BRANCH="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
 
# 0. Sanity — must be in a project that already has .gemini/ (i.e., harness was installed before)
if [ ! -d .gemini ]; then
  echo "ERROR: no .gemini/ directory in $(pwd)."
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
  report_diff "$TMP/harness/.gemini/agents/$a.md" ".gemini/agents/$a.md" ".gemini/agents/$a.md"
done

# Skills
for s in plan work review release setup orchestrator; do
  if [ -f "$TMP/harness/.gemini/skills/$s/SKILL.md" ]; then
    report_diff "$TMP/harness/.gemini/skills/$s/SKILL.md" ".gemini/skills/$s/SKILL.md" ".gemini/skills/$s/SKILL.md"
  fi
done

# Hooks
for h in block-destructive protect-secrets announce-agent; do
  report_diff "$TMP/harness/.gemini/hooks/$h.sh" ".gemini/hooks/$h.sh" ".gemini/hooks/$h.sh"
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
RV_CACHE_DIR=".gemini/.harness-cache/upstream-prev"
RV_CACHE="$RV_CACHE_DIR/reviewer.md"
RV_USER=".gemini/agents/reviewer.md"
RV_NEW="$TMP/harness/.gemini/agents/reviewer.md"
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
    echo "  ↻ .gemini/agents/reviewer.md  (will 3-way merge)"
  fi
fi

echo
echo "→ user files NOT touched (or auto-merged):"
echo "  · GEMINI.md"
echo "  · .gemini/settings*.json"
echo "  · .gemini/agents/reviewer.md  ↻ 3-way auto-merge if cache exists"
echo "  · .gemini/notes/, worktrees/"
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

# 4. Backup whole .gemini/agents and .gemini/skills and .gemini/hooks before overwrite
TS=$(date +%Y%m%d-%H%M%S)
BACKUP=".gemini/.harness-backup-$TS"
echo
echo "→ backup → $BACKUP/"
mkdir -p "$BACKUP"
[ -d .gemini/agents ] && cp -r .gemini/agents "$BACKUP/agents"
[ -d .gemini/skills ] && cp -r .gemini/skills "$BACKUP/skills"
[ -d .gemini/hooks  ] && cp -r .gemini/hooks  "$BACKUP/hooks"
[ -d scripts/harness ] && mkdir -p "$BACKUP/scripts" && cp -r scripts/harness "$BACKUP/scripts/"
[ -d docs/harness   ] && mkdir -p "$BACKUP/docs"    && cp -r docs/harness    "$BACKUP/docs/"
[ -f HARNESS.md     ] && cp HARNESS.md "$BACKUP/HARNESS.md"

# 5. Apply updates (selective)
echo "→ updating managed files"

mkdir -p .gemini/agents .gemini/skills .gemini/hooks scripts/harness docs/harness

# Standard agents (NOT reviewer)
for a in coder tester planner explorer documenter; do
  cp "$TMP/harness/.gemini/agents/$a.md" ".gemini/agents/$a.md"
done

# Skills
for s in plan work review release setup orchestrator; do
  if [ -d "$TMP/harness/.gemini/skills/$s" ]; then
    rm -rf ".gemini/skills/$s"
    cp -r "$TMP/harness/.gemini/skills/$s" ".gemini/skills/$s"
  fi
done

# Hooks
for h in block-destructive protect-secrets announce-agent; do
  cp "$TMP/harness/.gemini/hooks/$h.sh" ".gemini/hooks/$h.sh"
  chmod +x ".gemini/hooks/$h.sh"
done

# Duplicate to .claude/ if it exists (ensures dual compatibility for different CLI configurations)
if [ -d .claude ]; then
  echo "→ syncing updates to .claude/ (dual compatibility)"
  mkdir -p .claude/agents .claude/skills .claude/hooks
  
  for a in coder tester planner explorer documenter; do
    cp "$TMP/harness/.gemini/agents/$a.md" ".claude/agents/$a.md"
  done
  
  for s in plan work review release setup orchestrator; do
    if [ -d "$TMP/harness/.gemini/skills/$s" ]; then
      rm -rf ".claude/skills/$s"
      cp -r "$TMP/harness/.gemini/skills/$s" ".claude/skills/$s"
    fi
  done
  
  for h in block-destructive protect-secrets announce-agent; do
    cp "$TMP/harness/.gemini/hooks/$h.sh" ".claude/hooks/$h.sh"
    chmod +x ".claude/hooks/$h.sh"
  done
  
  # Also handle reviewer.md caching/sync for .claude if it is first-time
  if [ -f "$RV_NEW" ] && [ ! -f .claude/agents/reviewer.md ]; then
    cp "$RV_NEW" .claude/agents/reviewer.md
  fi
fi

# Duplicate to .agents/ if it exists (ensures antigravity-cli Workspace skill compatibility)
if [ -d .agents ]; then
  echo "→ syncing updates to .agents/ (Workspace skill compatibility)"
  mkdir -p .agents/agents .agents/skills
  
  for a in coder tester planner explorer documenter; do
    cp "$TMP/harness/.gemini/agents/$a.md" ".agents/agents/$a.md"
  done
  
  for s in plan work review release setup orchestrator; do
    if [ -d "$TMP/harness/.gemini/skills/$s" ]; then
      rm -rf ".agents/skills/$s"
      cp -r "$TMP/harness/.gemini/skills/$s" ".agents/skills/$s"
    fi
  done
  
  if [ -f "$RV_NEW" ] && [ ! -f .agents/agents/reviewer.md ]; then
    cp "$RV_NEW" .agents/agents/reviewer.md
  fi
fi

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
[ -f "$RV_NEW" ] && cp "$RV_NEW" "$BACKUP/reviewer.md.upstream-latest"

RV_RESULT=""
case "$RV_PLAN" in
  nochange)
    mkdir -p "$RV_CACHE_DIR"
    cp "$RV_NEW" "$RV_CACHE"
    ;;
  seed)
    mkdir -p "$RV_CACHE_DIR"
    cp "$RV_NEW" "$RV_CACHE"
    RV_RESULT="seed"
    ;;
  merge)
    MERGED=$(mktemp)
    if git merge-file -p --quiet "$RV_USER" "$RV_CACHE" "$RV_NEW" > "$MERGED" 2>/dev/null; then
      cp "$MERGED" "$RV_USER"
      RV_RESULT="clean"
    else
      cp "$MERGED" "$RV_USER"
      RV_RESULT="conflict"
    fi
    rm -f "$MERGED"
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
echo "   Restart Gemini CLI to load updated agent/skill definitions:"
echo "     > /exit"
echo "     $ gemini"
