#!/bin/bash
# PostToolUse hook for Edit|Write: auto-format Python files.
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

INPUT=$(cat)

# --- JSON extraction: jq -> python3 -> warn + exit 0 ---
if command -v jq >/dev/null 2>&1; then
  FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null) || FILE=""
elif command -v python3 >/dev/null 2>&1; then
  FILE=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    ti = json.load(sys.stdin).get("tool_input", {})
    print(ti.get("file_path") or ti.get("path") or "")
except Exception:
    pass
' 2>/dev/null) || FILE=""
else
  echo "[post-edit-lint] WARNING: jq and python3 both missing — auto-format skipped" >&2
  exit 0
fi
[ -z "$FILE" ] && exit 0
[ ! -f "$FILE" ] && exit 0

case "$FILE" in
  *.py) ;;
  *) exit 0 ;;
esac

hash_file() {  # shasum (macOS) -> sha1sum (Linux) -> cksum (POSIX)
  if command -v shasum >/dev/null 2>&1; then shasum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha1sum >/dev/null 2>&1; then sha1sum "$1" 2>/dev/null | awk '{print $1}'
  else cksum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

# Snapshot file content before formatting
HASH_BEFORE=$(hash_file "$FILE")

TOOL=""
if command -v ruff >/dev/null 2>&1; then
  ruff format "$FILE" >/dev/null 2>&1 && TOOL="ruff"
elif command -v black >/dev/null 2>&1; then
  black --quiet "$FILE" >/dev/null 2>&1 && TOOL="black"
fi

# No tool available → silent skip
[ -z "$TOOL" ] && exit 0

HASH_AFTER=$(hash_file "$FILE")
if [ "$HASH_BEFORE" != "$HASH_AFTER" ]; then
  echo "↳ auto-formatted by $TOOL: $FILE"
fi
exit 0
