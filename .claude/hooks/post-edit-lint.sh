#!/bin/bash
# PostToolUse hook for Edit|Write|MultiEdit: auto-format Python files.
#
# Purpose: realize the reviewer.md "low-nit policy" — let formatters (ruff/black)
# absorb style/format NITs automatically so reviewers focus on real issues.
#
# Behavior:
#   - .py files only (other extensions: silent skip)
#   - Tries ruff format first, falls back to black
#   - If neither tool is installed: silent skip
#   - Only emits stdout when the file actually changed (avoid noise)
#   - exit 0 always — never blocks the coder; lint failures are reviewer's job
#
# Why not run ruff check --fix?
#   - `format` is style-only (whitespace, line length, quotes); semantically safe
#   - `check --fix` can rename/remove things the coder intended → too aggressive
#     for an automatic post-edit hook. Reviewer handles that.

set -u
FILE=$(jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null || true)
[ -z "$FILE" ] && exit 0
[ ! -f "$FILE" ] && exit 0

case "$FILE" in
  *.py) ;;
  *) exit 0 ;;
esac

# Snapshot file content before formatting
HASH_BEFORE=$(shasum "$FILE" 2>/dev/null | awk '{print $1}')

TOOL=""
if command -v ruff >/dev/null 2>&1; then
  ruff format "$FILE" >/dev/null 2>&1 && TOOL="ruff"
elif command -v black >/dev/null 2>&1; then
  black --quiet "$FILE" >/dev/null 2>&1 && TOOL="black"
fi

# No tool available → silent skip
[ -z "$TOOL" ] && exit 0

HASH_AFTER=$(shasum "$FILE" 2>/dev/null | awk '{print $1}')
if [ "$HASH_BEFORE" != "$HASH_AFTER" ]; then
  echo "↳ auto-formatted by $TOOL: $FILE"
fi
exit 0
