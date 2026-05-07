#!/bin/bash
# Pre-tool-use hook: block destructive shell commands.
# Reads JSON from stdin, exits 2 (block) or 0 (allow).

set -u
CMD=$(jq -r '.tool_input.command // ""' 2>/dev/null || true)
[[ -z "$CMD" ]] && exit 0

block() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 2
}

# --- rm -rf on dangerous targets ---
if echo "$CMD" | grep -qE '(^|[[:space:];|&])rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*)'; then
  TARGETS=$(echo "$CMD" | sed -nE 's/.*rm[[:space:]]+-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]+(.*)/\1/p' | tr -s ' ;|&' '\n')
  while IFS= read -r tok; do
    [[ -z "$tok" || "$tok" =~ ^- ]] && continue
    # Quote tilde in patterns to prevent home-dir expansion.
    case "$tok" in
      "/"|"/*"|"*"|"~"|"~/"|"~/*"|"\$HOME"|"\$HOME/*"|"\${HOME}"|"\${HOME}/*")
        block "Refusing rm -rf on broad target '$tok'." ;;
      /bin*|/usr*|/etc*|/var*|/sbin*|/boot*|/dev*|/proc*|/sys*|/lib*|/Library*|/System*|/Applications*|/Users)
        block "Refusing rm -rf on system path '$tok'." ;;
    esac
  done <<< "$TARGETS"
fi

# --- git push --force / -f / --force-with-lease ---
# Match: --force, --force-with-lease, --force=..., -f, -f<sp/end>
if echo "$CMD" | grep -qE '(^|[[:space:];|&])git[[:space:]]+push([[:space:]]|$)'; then
  if echo "$CMD" | grep -qE '(--force(-with-lease)?([[:space:]=]|$)|[[:space:]]-f([[:space:]]|$))'; then
    block "git push --force is blocked. Use a fresh branch or a PR with reviewer sign-off."
  fi
fi

# --- git reset --hard origin/* ---
if echo "$CMD" | grep -qE 'git[[:space:]]+reset[[:space:]]+--hard[[:space:]]+origin/'; then
  block "git reset --hard origin/<branch> wipes local commits. Use git fetch + manual merge."
fi

# --- dd to physical disks ---
if echo "$CMD" | grep -qE 'dd([[:space:]]|.*[[:space:]])of=/dev/(sd|nvme|hd|disk)'; then
  block "dd of=/dev/* is blocked."
fi

exit 0
