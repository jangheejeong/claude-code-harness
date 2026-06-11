#!/bin/bash
# PreToolUse hook (matcher: Edit|Write): block writes to secret-bearing files.
# Deny protocol: human-readable reason on stderr + exit 2. Allow: exit 0, silent.
set -u

INPUT=$(cat)

# --- JSON extraction: jq -> python3 -> loud-warn fail-open (never silent) ---
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
  echo "[protect-secrets] WARNING: jq and python3 both missing — secret-write guard is DISABLED" >&2
  exit 0
fi
[ -z "$FILE" ] && exit 0

block() {
  echo "BLOCKED (protect-secrets.sh): $1" >&2
  exit 2
}

BASE="${FILE##*/}"

# Docs/templates that merely mention secret-ish words in their name are fine
# (.env.example, secret-rotation.md, ...).
case "$BASE" in
  *.md|*.txt|*.rst|*.example|*.sample|*.template) exit 0 ;;
esac

case "$BASE" in
  *.env|*.env.*|*.envrc)
    block "Refusing to write env files ('$BASE'). Edit them by hand if needed." ;;
  *.pem|*.key|*.p12|*.pfx|*.p8|*.keystore)
    block "Refusing to write key/cert files ('$BASE')." ;;
  id_rsa*|id_ed25519*)
    block "Refusing to write SSH key files ('$BASE')." ;;
  .npmrc|.pypirc|.htpasswd)
    block "Refusing to write auth config files ('$BASE') — they often hold tokens." ;;
  # Credential-shaped names only — source files like token_service.py or
  # design-tokens.css must pass.
  *credentials*.json|*credentials*.yaml|*credentials*.yml|*secret*.json|*secret*.yaml|*secret*.yml|*token*.json|*token*.yaml|*token*.yml)
    block "File name looks credential-bearing ('$BASE'). Refusing to write." ;;
  .*credentials*|.*secret*|.*token*)
    block "Dotfile name looks credential-bearing ('$BASE'). Refusing to write." ;;
  *.mcp.json|mcp.json)
    block "Refusing to write .mcp.json (may contain MCP tokens). Edit manually." ;;
esac

exit 0
