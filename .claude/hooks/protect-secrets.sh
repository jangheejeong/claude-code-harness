#!/bin/bash
# Pre-tool-use hook for Edit|Write: block writes to secret files.
set -u
PATH_=$(jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null || true)

if [[ -z "$PATH_" ]]; then
  exit 0
fi

block() {
  local reason="$1"
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 2
}

# Match path basename + simple patterns
case "$PATH_" in
  *.env|*.env.*|*.envrc) block "Refusing to write env files. Edit them by hand if needed." ;;
  *.pem|*.key|*.p12|*.pfx) block "Refusing to write key/cert files." ;;
  *credentials*|*secret*|*token*) 
     # allow doc files that just mention these words in their name
     case "$PATH_" in
       *.md|*.txt|*.rst) exit 0 ;;
       *) block "Path looks secret-bearing ('$PATH_'). Refusing to write." ;;
     esac
     ;;
  *.mcp.json|*/mcp.json) block "Refusing to write .mcp.json (may contain MCP tokens). Edit manually." ;;
esac

exit 0
