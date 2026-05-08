#!/bin/bash
# announce-agent.sh — print currently active subagent to the terminal.
# Wired as SubagentStart and SubagentStop hooks in settings.json.
#
# Output goes to /dev/tty (controlling terminal) so it shows in the foreground
# regardless of how Claude Code captures stdout/stderr.

set -u

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // .event_type // "unknown"' 2>/dev/null)
AGENT=$(echo "$INPUT" | jq -r '.agent_type // .agent_name // .matcher // .subagent_type // "unknown"' 2>/dev/null)
TS=$(date '+%H:%M:%S')

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
GRAY='\033[0;90m'
NC='\033[0m'  # no color

case "$EVENT" in
  SubagentStart|SubagentStarted|subagent_start)
    MSG="${GREEN}▶${NC} ${TS}  agent 시작: ${YELLOW}${AGENT}${NC}"
    ;;
  SubagentStop|SubagentStopped|subagent_stop)
    MSG="${GRAY}■${NC} ${TS}  agent 종료: ${GRAY}${AGENT}${NC}"
    ;;
  *)
    MSG="${GRAY}? ${TS}  ${EVENT}: ${AGENT}${NC}"
    ;;
esac

# Print to controlling terminal (foreground), fallback to stderr
{ echo -e "$MSG" > /dev/tty; } 2>/dev/null || echo -e "$MSG" >&2

# Also log to file for post-mortem inspection
mkdir -p .claude/notes 2>/dev/null
echo "${TS}  ${EVENT}  ${AGENT}" >> .claude/notes/agent-activity.log 2>/dev/null

exit 0
