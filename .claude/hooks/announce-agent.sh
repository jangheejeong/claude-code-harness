#!/bin/bash
# SubagentStart / SubagentStop hook: announce the active subagent on the
# terminal and append to .claude/notes/agent-activity.log.
# Payload (documented): {session_id, transcript_path, cwd, hook_event_name,
# agent_type} — the agent's name lives in `agent_type`.
# Cosmetic only: always exit 0, never block, never crash headless.

set -u

INPUT=$(cat 2>/dev/null) || INPUT=""

# --- JSON extraction: jq -> python3 -> warn + exit 0 ---
EVENT="unknown"
AGENT="unknown"
if command -v jq >/dev/null 2>&1; then
  EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "unknown"' 2>/dev/null) || EVENT="unknown"
  AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_type // .subagent_type // "unknown"' 2>/dev/null) || AGENT="unknown"
elif command -v python3 >/dev/null 2>&1; then
  OUT=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("hook_event_name") or "unknown")
print(d.get("agent_type") or d.get("subagent_type") or "unknown")
' 2>/dev/null) || OUT=""
  { IFS= read -r EVENT; IFS= read -r AGENT; } <<< "$OUT"
else
  echo "[announce-agent] WARNING: jq and python3 both missing — agent announce disabled" >&2
  exit 0
fi
[ -z "$EVENT" ] && EVENT="unknown"
[ -z "$AGENT" ] && AGENT="unknown"

TS=$(date '+%H:%M:%S')

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
GRAY='\033[0;90m'
NC='\033[0m'  # no color

case "$EVENT" in
  SubagentStart)
    MSG="${GREEN}▶${NC} ${TS}  agent 시작: ${YELLOW}${AGENT}${NC}"
    ;;
  SubagentStop)
    MSG="${GRAY}■${NC} ${TS}  agent 종료: ${GRAY}${AGENT}${NC}"
    ;;
  *)
    MSG="${GRAY}? ${TS}  ${EVENT}: ${AGENT}${NC}"
    ;;
esac

# Terminal line: only when a writable controlling terminal exists (headless-safe).
if [ -e /dev/tty ] && [ -w /dev/tty ]; then
  { printf '%b\n' "$MSG" > /dev/tty; } 2>/dev/null || true
fi

# Activity log: anchored to the project root, not the hook's cwd.
LOG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/notes"
mkdir -p "$LOG_DIR" 2>/dev/null || true
printf '%s  %s  %s\n' "$TS" "$EVENT" "$AGENT" >> "$LOG_DIR/agent-activity.log" 2>/dev/null || true

exit 0
