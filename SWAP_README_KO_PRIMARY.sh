#!/usr/bin/env bash
# Make Korean README the primary (README.md). English becomes README.en.md.
# Run from inside the claude-code-harness directory.
set -euo pipefail

cd "$(dirname "$0")"

# 0. Sanity
if [ ! -f README.md ] || [ ! -f README.ko.md ]; then
  echo "ERROR: README.md or README.ko.md missing here."
  exit 1
fi

# Detect which is currently which by looking at the language switcher
if grep -q '^\*\*English\*\* | \[한국어\]' README.md; then
  echo "→ README.md is currently English, README.ko.md is Korean. Swapping."
elif grep -q '^\*\*한국어\*\* | \[English\]' README.md; then
  echo "✅ README.md is already Korean — nothing to do."
  exit 0
else
  echo "WARN: language switcher pattern not recognized. Showing top of each file:"
  echo "--- README.md ---"; head -10 README.md
  echo "--- README.ko.md ---"; head -10 README.ko.md
  echo
  read -p "Proceed with swap anyway? [y/N] " ans
  [ "$ans" = "y" ] || exit 1
fi

# 1. Swap files (git mv preserves history)
git mv README.md README.en.md
git mv README.ko.md README.md

# 2. Rewrite language switchers in both files
python3 - <<'PY'
from pathlib import Path

# README.md is now the Korean version. Old switcher line:
#   [English](README.md) | **한국어**
# New (Korean primary, English link points to .en.md):
#   **한국어** | [English](README.en.md)
ko = Path("README.md")
text = ko.read_text()
text = text.replace(
    "[English](README.md) | **한국어**",
    "**한국어** | [English](README.en.md)",
    1,
)
ko.write_text(text)

# README.en.md is now the English version. Old switcher line:
#   **English** | [한국어](README.ko.md)
# New (English secondary, Korean link points to README.md):
#   [한국어](README.md) | **English**
en = Path("README.en.md")
text = en.read_text()
text = text.replace(
    "**English** | [한국어](README.ko.md)",
    "[한국어](README.md) | **English**",
    1,
)
en.write_text(text)
print("→ language switchers updated")
PY

# 3. Commit + push
git add README.md README.en.md
echo
echo "→ Diff preview:"
git diff --cached --stat
echo
git commit -m "docs: make Korean README primary, English moves to README.en.md"

if git remote get-url origin >/dev/null 2>&1; then
  git push
  echo
  echo "✅ Done. View at:"
  echo "   https://github.com/jangheejeong/claude-code-harness"
  echo "   (first page should now be Korean)"
else
  echo
  echo "✅ Local commit done. No 'origin' remote — push manually when ready."
fi
