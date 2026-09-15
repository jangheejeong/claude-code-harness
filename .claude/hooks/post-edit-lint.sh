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

toml_declares() {  # <pyproject.toml> <ruff|black>: does it hold a [tool.<x>] table?
  # Anchored at the start of a line so a `# [tool.black]` comment does not count.
  # The trailing class keeps [tool.ruff.format] in and a [tool.ruffx] out.
  grep -qE "^[[:space:]]*\[tool\.$2(\]|\.)" "$1" 2>/dev/null
}

declared_in() {  # <dir> -> "ruff" | "black" | "" — what this one directory declares
  # A dedicated ruff file needs no table inside it — its name is the declaration.
  if [ -f "$1/ruff.toml" ] || [ -f "$1/.ruff.toml" ]; then printf ruff; return; fi
  if [ -f "$1/pyproject.toml" ]; then
    if toml_declares "$1/pyproject.toml" ruff; then printf ruff; return; fi
    if toml_declares "$1/pyproject.toml" black; then printf black; return; fi
  fi
}

project_formatter() {  # <dir> -> the formatter declared at or above <dir>, "" if none
  local dir="$1" found parent
  while [ -n "$dir" ]; do
    found=$(declared_in "$dir")
    [ -n "$found" ] && { printf '%s' "$found"; return; }
    # Stop at the repo root. ~/Projects/heum is a plain directory holding
    # independent repos side by side, so climbing past one would hand a repo
    # whatever its neighbour, or the home directory, happens to declare.
    # `-e` and not `-d`: in a git worktree .git is a file, and a worktree is
    # every bit as much a boundary as a clone.
    [ -e "$dir/.git" ] && return
    parent=$(dirname "$dir")
    [ "$parent" = "$dir" ] && return   # reached /, nothing above it
    dir="$parent"
  done
}

DIR=$(cd "$(dirname "$FILE")" 2>/dev/null && pwd) || exit 0
TOOL=$(project_formatter "$DIR")

# Nothing declared → nothing runs. A repo that never chose a style does not get
# one chosen for it; imposing ruff's defaults there is the same defect as the
# 88-column fold, only quieter.
[ -z "$TOOL" ] && exit 0

# Snapshot file content before formatting
HASH_BEFORE=$(hash_file "$FILE")

# One arm per declared tool and deliberately no fallback arm: if the declared
# formatter is not installed the command fails, nothing is written, and the hook
# says nothing. Do not add an `else run the other one` here — that is exactly how
# a repo asking for black at 120 columns got folded by ruff at 88, which is the
# bug this file was rewritten to remove. A missing tool is a machine set up
# wrong; formatting nothing reports that honestly.
case "$TOOL" in
  ruff)  ruff format "$FILE" >/dev/null 2>&1 ;;
  black) black --quiet "$FILE" >/dev/null 2>&1 ;;
esac

HASH_AFTER=$(hash_file "$FILE")
if [ "$HASH_BEFORE" != "$HASH_AFTER" ]; then
  echo "↳ auto-formatted by $TOOL: $FILE"
fi
exit 0
