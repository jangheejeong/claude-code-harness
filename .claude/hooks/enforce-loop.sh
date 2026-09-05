#!/bin/bash
# Stop hook: enforce the auto-fix loop budget recorded by record-verdict.sh.
# Payload (documented): {session_id, transcript_path, cwd, hook_event_name,
# stop_hook_active}.
#
# This is the judging half of design decision D1. Stop's exit 2 means "prevent
# Claude from stopping, continue the conversation", so the main session gets
# control back and can re-dispatch the coder; the reason on stderr is what the
# model reads. The recording half lives in record-verdict.sh on SubagentStop,
# whose exit 2 would instead keep the read-only reviewer running. Do not merge
# the two hooks.

set -u

STATE_FILE="${CLAUDE_PROJECT_DIR:-.}/.claude/notes/loop-state.json"
MAX_ATTEMPTS=3  # the "auto-fix loop max 3" the harness skills have always claimed

warn() { echo "[enforce-loop] WARNING: $*" >&2; }

INPUT=$(cat 2>/dev/null) || INPUT=""

# Stop fires at the end of every main turn, ordinary conversation included.
# No state file means no review loop is in flight, so leave before judging
# anything — a leak here would trap plain chat in a hook it never asked for.
[ -f "$STATE_FILE" ] || exit 0

# --- state read: jq -> python3 -> warn + exit 0 (as in announce-agent.sh) ---
VERDICT=""
ATTEMPT=0
if command -v jq >/dev/null 2>&1; then
  VERDICT=$(jq -r '.last_verdict // ""' "$STATE_FILE" 2>/dev/null) || VERDICT=""
  ATTEMPT=$(jq -r '.attempt // 0' "$STATE_FILE" 2>/dev/null) || ATTEMPT=0
elif command -v python3 >/dev/null 2>&1; then
  OUT=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        state = json.load(f)
except Exception:
    state = {}
if not isinstance(state, dict):
    state = {}
print(state.get("last_verdict") or "")
print(state.get("attempt") or 0)
' "$STATE_FILE" 2>/dev/null) || OUT=""
  { IFS= read -r VERDICT; IFS= read -r ATTEMPT; } <<< "$OUT"
else
  warn "jq and python3 both missing — loop enforcement disabled"
  exit 0
fi

# The reviewer's own wording ("REQUEST CHANGES") and run_phase.py's normalized
# form ("CHANGES") both mean the same thing here. APPROVE and UNKNOWN do not:
# UNKNOWN is "no judgement was made", which reopens the pre-hook behaviour.
needs_fixing() {  # <verdict>
  case "$1" in
    BLOCK | CHANGES | "REQUEST CHANGES") return 0 ;;
    *) return 1 ;;
  esac
}

needs_fixing "$VERDICT" || exit 0

# Exit 2 on Stop = "do not stop, continue the conversation". stderr is what the
# model reads, so it has to be an instruction, not just a complaint.
{
  echo "[enforce-loop] Reviewer verdict ${VERDICT} — the phase is not done (attempt ${ATTEMPT}/${MAX_ATTEMPTS})."
  echo "Re-dispatch the coder in fix mode with the reviewer's findings, then re-run the reviewer."
} >&2
exit 2
