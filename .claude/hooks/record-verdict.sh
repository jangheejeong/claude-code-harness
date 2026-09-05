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

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_PHASE="$HOOK_DIR/../../scripts/harness/run_phase.py"
STATE_FILE="${CLAUDE_PROJECT_DIR:-.}/.claude/notes/loop-state.json"

warn() { echo "[record-verdict] WARNING: $*" >&2; }

INPUT=$(cat 2>/dev/null) || INPUT=""

# --- JSON extraction: jq -> python3 -> warn + exit 0 (as in announce-agent.sh) ---
AGENT="unknown"
TRANSCRIPT=""
if command -v jq >/dev/null 2>&1; then
  AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_type // .subagent_type // "unknown"' 2>/dev/null) || AGENT="unknown"
  TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.agent_transcript_path // .transcript_path // ""' 2>/dev/null) || TRANSCRIPT=""
elif command -v python3 >/dev/null 2>&1; then
  OUT=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("agent_type") or d.get("subagent_type") or "unknown")
print(d.get("agent_transcript_path") or d.get("transcript_path") or "")
' 2>/dev/null) || OUT=""
  { IFS= read -r AGENT; IFS= read -r TRANSCRIPT; } <<< "$OUT"
else
  warn "jq and python3 both missing — verdict recording disabled"
  exit 0
fi
[ -z "$AGENT" ] && AGENT="unknown"

# Only the reviewer owns the loop counter. Anyone else stopping says nothing
# about the review, so neither create nor touch the state file.
[ "$AGENT" = "reviewer" ] || exit 0

# Past this point python3 is not optional: the verdict parser is run_phase.py,
# and reimplementing its placement rule in bash would let the two drift.
if ! command -v python3 >/dev/null 2>&1; then
  warn "python3 missing — cannot parse the reviewer verdict"
  exit 0
fi

# The transcript is JSON Lines. The reviewer's conclusion is the text of its
# last assistant record; thinking blocks are excluded on purpose, because a
# reviewer may quote a <verdict> tag while deliberating and only its final
# answer is a judgement.
final_assistant_text() {  # <transcript.jsonl>
  python3 - "$1" <<'PY'
import json, sys

last = ""
with open(sys.argv[1], errors="replace") as f:
    for line in f:
        try:
            record = json.loads(line)
        except ValueError:
            continue  # a partially flushed line is not a reason to give up
        if not isinstance(record, dict) or record.get("type") != "assistant":
            continue
        content = (record.get("message") or {}).get("content")
        if isinstance(content, str):
            blocks = [content]
        else:
            blocks = [
                b.get("text") or ""
                for b in (content or [])
                if isinstance(b, dict) and b.get("type") == "text"
            ]
        text = "\n".join(b for b in blocks if b)
        # Skip records that carried only thinking or tool calls: the answer is
        # the last assistant record that actually said something.
        if text.strip():
            last = text
sys.stdout.write(last)
PY
}

# Preserves keys this hook does not know about, so Phase 3 can add its own.
record_state() {  # <verdict>
  python3 - "$STATE_FILE" "$1" <<'PY'
import json, sys

path, verdict = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        state = json.load(f)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}  # missing or corrupt: restart the count rather than refuse to record
try:
    attempt = int(state.get("attempt", 0))
except (TypeError, ValueError):
    attempt = 0

state["last_verdict"] = verdict
if verdict == "APPROVE":
    state["attempt"] = 0  # the loop ended: hand the budget back to the next phase
elif verdict == "UNKNOWN":
    state["attempt"] = attempt  # no judgement was made, so no attempt was spent
else:
    state["attempt"] = attempt + 1

with open(path, "w") as f:
    json.dump(state, f)
    f.write("\n")
PY
}

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  warn "no readable agent transcript ('${TRANSCRIPT}') — verdict not recorded"
  exit 0
fi

ANSWER=$(mktemp "${TMPDIR:-/tmp}/record-verdict-XXXXXX") || exit 0
trap 'rm -f "$ANSWER"' EXIT
final_assistant_text "$TRANSCRIPT" > "$ANSWER" 2>/dev/null || {
  warn "could not read the agent transcript $TRANSCRIPT"
  exit 0
}

# run_phase.py owns the placement rule; exit 1 means it could not read the file.
# The other exit codes (0/4/5) all carry a verdict on stdout.
PARSE_RC=0
VERDICT=$(python3 "$RUN_PHASE" --parse-verdict "$ANSWER") || PARSE_RC=$?
if [ "$PARSE_RC" -eq 1 ]; then
  warn "run_phase.py could not parse the verdict — nothing recorded"
  exit 0
fi

mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
record_state "$VERDICT" || warn "could not write $STATE_FILE"

exit 0
