#!/bin/bash
# SubagentStop hook: record a finished reviewer's verdict to
# .claude/notes/loop-state.json so the Stop hook can enforce the retry budget.
# Payload (documented): {session_id, transcript_path, cwd, hook_event_name,
# agent_type, agent_transcript_path} — the subagent's own transcript is the
# `agent_transcript_path` one.
#
# Records only, ALWAYS exit 0 (design decision D1). SubagentStop's exit 2 means
# "prevent the subagent from stopping", which would just keep the read-only
# reviewer running — it cannot fix anything. Judgement lives in enforce-loop.sh
# on Stop, whose exit 2 hands control back to the main session. Do not merge
# these two hooks.

set -u

INPUT=$(cat 2>/dev/null) || INPUT=""

# --- JSON extraction: jq -> python3 -> warn + exit 0 (as in announce-agent.sh) ---
AGENT="unknown"
if command -v jq >/dev/null 2>&1; then
  AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_type // .subagent_type // "unknown"' 2>/dev/null) || AGENT="unknown"
elif command -v python3 >/dev/null 2>&1; then
  AGENT=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("agent_type") or d.get("subagent_type") or "unknown")
' 2>/dev/null) || AGENT="unknown"
else
  echo "[record-verdict] WARNING: jq and python3 both missing — verdict recording disabled" >&2
  exit 0
fi
[ -z "$AGENT" ] && AGENT="unknown"

# Only the reviewer owns the loop counter. Anyone else stopping says nothing
# about the review, so neither create nor touch the state file.
[ "$AGENT" = "reviewer" ] || exit 0

exit 0
