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

# The hook and the parser ship in the same repo, so the path to the parser is
# derived from $0 rather than from $CLAUDE_PROJECT_DIR.
#
# Shell builtins do the work: this runs before the jq/python3 check, and on a
# host without them a `dirname: command not found` would drown out the one
# warning this hook exists to print. readlink is the single exception and it is
# only reached for a path that `-L` already proved is a symlink, with its own
# failure swallowed.
self_dir() {
  local self="$0" target hops=0
  # $0 is whatever the caller typed. settings.json passes an absolute path, but
  # a wrapper or a hand run may pass a bare name or a symlink, and `${0%/*}`
  # returns $0 unchanged when there is no slash to strip — that silently built
  # the path "record-verdict.sh/../../scripts/harness/run_phase.py", which no
  # python3 can open.
  while [ -L "$self" ] && [ "$hops" -lt 16 ]; do  # 16: a cycle is not our problem to solve
    target=$(readlink "$self" 2>/dev/null) || break
    case "$target" in
      /*) self="$target" ;;
      *) self="${self%/*}/$target" ;;  # a relative link resolves against the link's own dir
    esac
    hops=$((hops + 1))
  done
  case "$self" in
    */*) printf '%s' "${self%/*}" ;;
    *) printf '%s' "." ;;
  esac
}
RUN_PHASE="$(self_dir)/../../scripts/harness/run_phase.py"
STATE_FILE="${CLAUDE_PROJECT_DIR:-.}/.claude/notes/loop-state.json"

warn() { echo "[record-verdict] WARNING: $*" >&2; }

INPUT=$(cat 2>/dev/null) || INPUT=""

# --- JSON extraction: jq -> python3 -> warn + exit 0 (as in announce-agent.sh) ---
AGENT="unknown"
TRANSCRIPT=""
if command -v jq >/dev/null 2>&1; then
  AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_type // .subagent_type // "unknown"' 2>/dev/null) || AGENT="unknown"
  TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.agent_transcript_path // ""' 2>/dev/null) || TRANSCRIPT=""
elif command -v python3 >/dev/null 2>&1; then
  OUT=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}


def one_line(value):
    # A newline is the field separator below, so it cannot survive inside a
    # value: one in agent_type would push the transcript path up a line and
    # make this branch read a verdict out of a file the payload never named.
    return str(value).replace("\n", " ").replace("\r", " ")


print(one_line(d.get("agent_type") or d.get("subagent_type") or "unknown"))
print(one_line(d.get("agent_transcript_path") or ""))
' 2>/dev/null) || OUT=""
  { IFS= read -r AGENT; IFS= read -r TRANSCRIPT; } <<< "$OUT"
else
  warn "jq and python3 both missing — verdict recording disabled"
  exit 0
fi
[ -z "$AGENT" ] && AGENT="unknown"

# Only the reviewer owns the loop counter. Anyone else stopping says nothing
# about the review, so neither create nor touch the state file.
#
# A reviewer spawned as a teammate arrives under its teammate name —
# "reviewer-phase2" and the like, as .claude/notes/agent-activity.log shows. An
# exact match turns the whole loop off on that path and leaves no trace that it
# was off. The prefix stays a prefix: "code-reviewer" is somebody else.
case "$AGENT" in
  reviewer | reviewer-*) ;;
  *) exit 0 ;;
esac

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
# A new verdict has not been acted on yet. enforce-loop.sh flips this to true
# when it spends the verdict on one re-dispatch, which is what keeps a loop the
# user walked away from from blocking the end of every future turn. Do not drop
# it as redundant bookkeeping: without it an abandoned BLOCK on disk is
# indistinguishable from a live one.
state["enforced"] = False
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

# Only `agent_transcript_path` is the subagent's own transcript. `transcript_path`
# in the same payload is the MAIN session's, and its last assistant text is
# whatever the main session said — if that quoted a verdict, this hook would
# record a judgement the reviewer never made. Do not restore it as a fallback:
# on a build that does not send agent_transcript_path there is nothing here to
# read, and silently reading the wrong file is the failure this hook exists to
# remove.
if [ -z "$TRANSCRIPT" ]; then
  warn "payload carried no agent_transcript_path — verdict not recorded"
  exit 0
fi
if [ ! -f "$TRANSCRIPT" ]; then
  warn "no readable agent transcript ('${TRANSCRIPT}') — verdict not recorded"
  exit 0
fi

ANSWER=$(mktemp "${TMPDIR:-/tmp}/record-verdict-XXXXXX") || exit 0
trap 'rm -f "$ANSWER"' EXIT
final_assistant_text "$TRANSCRIPT" > "$ANSWER" 2>/dev/null || {
  warn "could not read the agent transcript $TRANSCRIPT"
  exit 0
}

# run_phase.py owns the placement rule. Exactly three exit codes carry a verdict
# on stdout: 0 = APPROVE/UNKNOWN, 4 = CHANGES, 5 = BLOCK (D5).
#
# The list is of the codes that DO carry a verdict, not of the known failure
# ones — do not narrow it back to `[ "$PARSE_RC" -eq 1 ]`. Filtering only the
# documented failure lets every undocumented one through: python3's own exit 2
# when $RUN_PHASE is not there, a traceback from a future change to the parser.
# Those arrive with VERDICT empty, and an empty verdict is the worst value this
# hook can write — record_state counts it as a spent attempt (one of the three
# gone), while enforce-loop.sh reads it as "no verdict to enforce" and releases
# the turn. The counter this hook exists to keep would be corrupted by the very
# failure nobody looks at.
PARSE_RC=0
VERDICT=$(python3 "$RUN_PHASE" --parse-verdict "$ANSWER") || PARSE_RC=$?
case "$PARSE_RC" in
  0 | 4 | 5) ;;
  *)
    warn "run_phase.py exited $PARSE_RC without a verdict — nothing recorded"
    exit 0
    ;;
esac

# Checked separately on purpose: the exit code and the word on stdout can fail
# independently. A parser that exits 0 having printed nothing (or something this
# hook does not know) must not reach record_state either.
case "$VERDICT" in
  APPROVE | CHANGES | BLOCK | UNKNOWN) ;;
  *)
    warn "run_phase.py printed no recognisable verdict ('${VERDICT}') — nothing recorded"
    exit 0
    ;;
esac

mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
record_state "$VERDICT" || warn "could not write $STATE_FILE"

exit 0
