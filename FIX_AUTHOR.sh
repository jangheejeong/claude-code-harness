#!/usr/bin/env bash
# Rewrite all commits in this repo to use a personal noreply email.
# Run from inside the claude-code-harness directory.
set -euo pipefail

REAL_NAME='jangheejeong'
REAL_EMAIL='43447077+jangheejeong@users.noreply.github.com'

cd "$(dirname "$0")"

if [ ! -d .git ]; then
  echo "ERROR: no .git/ here. Run this inside the claude-code-harness directory."
  exit 1
fi

echo "→ Before:"
git log --pretty=format:'  %h %an <%ae>  %s' -5
echo
echo

echo "→ Rewriting all commits with author/committer = $REAL_NAME <$REAL_EMAIL>"
# Suppress filter-branch's "glut of gotchas" warning (we know what we're doing, single-author solo repo)
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --env-filter "
export GIT_AUTHOR_NAME='$REAL_NAME'
export GIT_AUTHOR_EMAIL='$REAL_EMAIL'
export GIT_COMMITTER_NAME='$REAL_NAME'
export GIT_COMMITTER_EMAIL='$REAL_EMAIL'
" --tag-name-filter cat -- --branches --tags

echo
echo "→ Setting local repo config so future commits inherit personal credentials"
git config user.name  "$REAL_NAME"
git config user.email "$REAL_EMAIL"

echo
echo "→ After:"
git log --pretty=format:'  %h %an <%ae>  %s' -5
echo
echo

echo "→ Force pushing rewritten history"
if git remote get-url origin >/dev/null 2>&1; then
  git push --force-with-lease origin main
  echo
  echo "✅ Done. Verify on GitHub:"
  echo "   https://github.com/${REAL_NAME}/$(basename "$(pwd)")/commits/main"
  echo "   (avatar next to the top commit should be your personal profile)"
else
  echo "  no 'origin' remote configured — skipping push."
  echo "  If you want to push manually:"
  echo "    git remote add origin https://github.com/${REAL_NAME}/$(basename "$(pwd)").git"
  echo "    git push -u origin main --force-with-lease"
fi
