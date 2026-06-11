#!/bin/bash
# PreToolUse hook (matcher: Bash): block destructive shell commands.
# Deny protocol: human-readable reason on stderr + exit 2. Allow: exit 0, silent.
# Known limits (by design — this is not a full shell parser): variable targets
# ($T), `xargs rm`, and quoted `sh -c '...'` payloads are not inspected.

set -u
set -f  # no globbing: we word-split untrusted command text below

INPUT=$(cat)

# --- JSON extraction: jq -> python3 -> loud-warn fail-open ---
# Fail-open is deliberate: bricking every Bash call on a host without jq AND
# python3 is worse than losing the guard. But never fail open silently.
if command -v jq >/dev/null 2>&1; then
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null) || CMD=""
elif command -v python3 >/dev/null 2>&1; then
  CMD=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
except Exception:
    pass
' 2>/dev/null) || CMD=""
else
  echo "[block-destructive] WARNING: jq and python3 both missing — destructive-command guard is DISABLED" >&2
  exit 0
fi
[ -z "$CMD" ] && exit 0

block() {
  echo "BLOCKED (block-destructive.sh): $1" >&2
  exit 2
}

strip_wrap() {  # strip one layer of parens/quotes around a token
  local t="$1"
  t="${t#\(}"; t="${t%\)}"
  t="${t#\"}"; t="${t%\"}"
  t="${t#\'}"; t="${t%\'}"
  printf '%s' "$t"
}

# --- rm with recursive+force flags on dangerous targets (per segment) ---
check_rm() {
  local seg="$1" tok t saw_rm=0 has_r=0 has_f=0 skip_next=0 targets=""
  for tok in $seg; do
    if [ "$saw_rm" -eq 0 ]; then
      case "${tok#\(}" in rm|*/rm) saw_rm=1 ;; esac
      continue
    fi
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    case "$tok" in
      ">"|">>"|"<"|[0-9]">"|[0-9]">>") skip_next=1; continue ;;  # redirect target follows
      ">"*|"<"*|[0-9]">"*) continue ;;                            # attached redirect
    esac
    case "$tok" in
      --recursive) has_r=1 ;;
      --force)     has_f=1 ;;
      --*) : ;;
      -?*)
        case "$tok" in *r*|*R*) has_r=1 ;; esac
        case "$tok" in *f*)     has_f=1 ;; esac
        ;;
      *) targets="$targets $tok" ;;
    esac
  done
  [ "$saw_rm" -eq 1 ] && [ "$has_r" -eq 1 ] && [ "$has_f" -eq 1 ] || return 0
  for tok in $targets; do
    t=$(strip_wrap "$tok")
    case "$t" in
      "/"|"/*"|"*"|"~"|"~/"|"~/*"|'$HOME'|'$HOME/*'|'${HOME}'|'${HOME}/*')
        block "Refusing rm -rf on broad target '$t'." ;;
      # Anchored (exact dir or under it) — '/dev*' style would also match /development.
      /bin|/bin/*|/usr|/usr/*|/etc|/etc/*|/var|/var/*|/sbin|/sbin/*|/boot|/boot/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/lib|/lib/*|/lib64|/lib64/*|/Library|/Library/*|/System|/System/*|/Applications|/Applications/*|/Users)
        block "Refusing rm -rf on system path '$t'." ;;
    esac
  done
  return 0
}

# --- git push --force / -f / --force-with-lease / +refspec (per segment) ---
check_git_push() {
  local seg="$1" tok t saw_git=0 saw_push=0
  for tok in $seg; do
    if [ "$saw_git" -eq 0 ]; then
      case "${tok#\(}" in git|*/git) saw_git=1 ;; esac
      continue
    fi
    if [ "$saw_push" -eq 0 ]; then
      [ "$tok" = "push" ] && saw_push=1   # global flags (-C <path>, -c k=v) skipped
      continue
    fi
    t=$(strip_wrap "$tok")
    case "$t" in
      --force|--force=*|--force-with-lease|--force-with-lease=*)
        block "git push --force is blocked. Use a fresh branch or a PR with reviewer sign-off." ;;
      --*) : ;;
      -[!-]*)
        case "$t" in
          *f*) block "git push -f (force) is blocked. Use a fresh branch or a PR with reviewer sign-off." ;;
        esac
        ;;
      +*)
        block "git push with a +refspec ('$t') is a force push and is blocked." ;;
    esac
  done
  return 0
}

# Inspect EVERY pipeline/compound segment, not just the last one.
SEGS=$(printf '%s\n' "$CMD" | tr ';|&' '\n')
while IFS= read -r seg; do
  case "$seg" in *[![:space:]]*) ;; *) continue ;; esac
  check_rm "$seg"
  check_git_push "$seg"
done <<< "$SEGS"

# --- git reset --hard origin/* ---
RE_RESET='git[[:space:]]+reset[[:space:]]+--hard[[:space:]]+origin/'
if [[ $CMD =~ $RE_RESET ]]; then
  block "git reset --hard origin/<branch> wipes local commits. Use git fetch + manual merge."
fi

# --- dd to physical disks (incl. macOS raw devices /dev/rdisk*) ---
RE_DD='(^|[[:space:];|&(])dd[[:space:]]'
RE_DD_OUT='of=/dev/(r?disk|sd|nvme|hd)'
if [[ $CMD =~ $RE_DD ]] && [[ $CMD =~ $RE_DD_OUT ]]; then
  block "dd of=/dev/<physical disk> is blocked."
fi

exit 0
