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

# A reviewer ran and its verdict did not reach the state file. That used to end
# here, as one line on stderr — which the user sees only in transcript mode, and
# which nothing downstream can read. Since consume-once, the previous verdict is
# already spent by then, so the next Stop finds nothing to react to and the turn
# simply ends: the loop stops being enforced and says nothing about it.
#
# The mark is how that reaches enforce-loop.sh, which announces it once and
# clears it. It carries nothing else: last_verdict and attempt are what this run
# failed to determine, and inventing either is the failure it is reporting.
#
# Every caller is a path that has already decided not to record. Nothing here
# may fail loudly either — the hook still owes SubagentStop an exit 0 (D1).
mark_record_failure() {  # <one-line reason>
  # No python3, no JSON writer here: that host keeps the stderr warning it always
  # had, and every other host gets the mark. enforce-loop.sh does carry a jq
  # render-and-rename, but only for *clearing* — a mark it cannot clear repeats
  # on every turn for good, while a mark that is never written leaves this host
  # exactly as loud as it was before.
  command -v python3 >/dev/null 2>&1 || return 0
  mkdir -p "${STATE_FILE%/*}" 2>/dev/null || true
  python3 - "$STATE_FILE" "$1" <<'PY' 2>/dev/null || true
import json, os, sys

path, reason = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        state = json.load(f)
    if not isinstance(state, dict):
        state = {}
except FileNotFoundError:
    state = {}
except Exception:
    # Unreadable is not the same as missing: a state file that is there but
    # corrupt still holds a budget somebody may yet repair by hand, and
    # replacing it with a mark would throw that away to report a smaller
    # problem. enforce-loop.sh already warns loudly about a file it cannot read.
    raise SystemExit(0)

state["record_failed"] = True
# enforce-loop.sh's python3 branch reads the state file one field per line, so a
# newline in here would push every later field down one and have it judge a
# budget the file never held.
state["record_failed_reason"] = reason.replace("\n", " ").replace("\r", " ")

tmp = "%s.%d.tmp" % (path, os.getpid())  # a name no other writer can be holding
with open(tmp, "w") as f:
    json.dump(state, f)
    f.write("\n")
os.replace(tmp, path)  # a reader sees the old file or the new one, never half of one
PY
}

# Every path that gives up on a reviewer's verdict goes through here, so that
# "warned" and "marked" cannot drift apart.
give_up() {  # <one-line reason>
  warn "$1"
  mark_record_failure "$1"
  exit 0
}

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
  give_up "python3 missing — cannot parse the reviewer verdict"
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

# One value that changes whenever anything a coder could have touched changed.
# enforce-loop.sh compares two consecutive cycles' worth of these and stops a
# loop that is not moving, so what this covers is what that can see:
#   - HEAD, for work the coder committed
#   - the tracked diff against HEAD, for work it has not committed yet
#   - the porcelain status, whose untracked entries `git diff HEAD` cannot see
#   - the contents of those untracked entries, which the status line does not
#     carry: `?? path` is the same line whether the file holds a stub or a
#     finished module, and a coder iterating on something it never added would
#     otherwise read as a coder that did nothing
# Dropping any of the four would call a real cycle stalled — a coder that only
# wrote a test file and never committed is the ordinary mid-loop shape here.
#
# It stays a floor rather than a net: it sees files, not intent, so a cycle that
# only reformatted a line still counts as movement. The real judgement is the
# reviewer's either way.
#
# Empty is a valid answer: no git, no repo, no commits yet. Never a constant,
# though — a placeholder would compare equal to itself and stop every loop.
diff_fingerprint() {  # -> hash of the repo's current state, or "" if unavailable
  local dir="${CLAUDE_PROJECT_DIR:-.}"
  command -v git >/dev/null 2>&1 || return 0
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  # `.claude/notes/` is where this hook and announce-agent.sh do their own
  # writing, and in a project that does not gitignore it every cycle would
  # differ by the state file this very run is about to write — the fingerprint
  # would never repeat and no-progress detection would be permanently off.
  # `-uall` for the same reason in reverse: without it git collapses a wholly
  # untracked directory to one `?? .claude/` line, and a second new file inside
  # it would leave the fingerprint unchanged.
  {
    git -C "$dir" rev-parse HEAD 2>/dev/null
    git -C "$dir" status --porcelain -uall -- ':(exclude).claude/notes' 2>/dev/null
    git -C "$dir" diff HEAD -- ':(exclude).claude/notes' 2>/dev/null
    # One blob id per untracked file, which is the only place their contents
    # appear at all. `--exclude-standard` keeps gitignored trees (node_modules
    # and friends) out, so what is hashed is what a coder could have written.
    #
    # The readability filter is not tidiness. `git hash-object` open()s each
    # argument and die()s on the first one it cannot, abandoning every argument
    # after it — so one dangling symlink sorting early drops the contents of
    # every untracked file behind it, while its own `?? path` line above stays
    # exactly the same whatever those files then hold. The fingerprint freezes,
    # and a live loop is cut short as "무진전" with budget still on it: the
    # false stop this list was added to prevent, back through another door.
    #
    # `[ -f ]` resolves the link before it answers, so a broken one fails here
    # and a link to a real file still passes (hash-object follows it too, and
    # hashes what it points at). What the filter drops — broken links, links to
    # directories, mode-000 files, anything that is not a regular file, and a
    # path deleted in the window since ls-files — reaches the fingerprint by
    # name through the porcelain status above and by contents not at all. That
    # is a blind spot the size of "a cycle whose only work was re-pointing a
    # broken symlink", and the alternative is no untracked contents at all.
    #
    # Builtins only, so this stays one subshell rather than one fork per file.
    # Measured on this repo: ~3ms with no untracked files, ~30ms with 500 of
    # them, against a hook that runs once per reviewer stop.
    git -C "$dir" ls-files --others --exclude-standard -z -- ':(exclude).claude/notes' 2>/dev/null \
      | { while IFS= read -r -d '' f; do
            [ -f "$dir/$f" ] && [ -r "$dir/$f" ] && printf '%s\0' "$f"
          done; } \
      | xargs -0 -r git -C "$dir" hash-object -- 2>/dev/null
  } | git -C "$dir" hash-object --stdin 2>/dev/null || return 0
}

# Preserves keys this hook does not know about.
record_state() {  # <verdict> <diff-fingerprint|"">
  python3 - "$STATE_FILE" "$1" "$2" <<'PY'
import json, os, sys

path, verdict, fingerprint = sys.argv[1], sys.argv[2], sys.argv[3]
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
# Whatever an earlier run could not read, this one could. Leaving the mark would
# make a parser that broke once announce itself in every session after the one
# it broke in.
state.pop("record_failed", None)
state.pop("record_failed_reason", None)
# A new verdict has not been acted on yet. enforce-loop.sh flips this to true
# when it spends the verdict on one re-dispatch, which is what keeps a loop the
# user walked away from from blocking the end of every future turn. Do not drop
# it as redundant bookkeeping: without it an abandoned BLOCK on disk is
# indistinguishable from a live one.
state["enforced"] = False

def forget_progress():
    # Whatever pair is on disk describes cycles that are no longer adjacent to
    # the next one. Comparing across the gap would answer a question nobody
    # asked, and the answer it would give is "stalled".
    state.pop("prev_diff_sha", None)
    state.pop("last_diff_sha", None)


if verdict == "APPROVE":
    state["attempt"] = 0  # the loop ended: hand the budget back to the next phase
    forget_progress()  # the budget goes back, and so does what it is measured against
elif verdict == "UNKNOWN":
    state["attempt"] = attempt  # no judgement was made, so no attempt was spent
    # ...and no cycle happened either, so the fingerprints stay as they are: the
    # next judged cycle is compared against the last judged one, not against a
    # review that never reached a verdict.
else:
    state["attempt"] = attempt + 1
    if fingerprint:
        # The same rule the readers enforce (enforce-loop.sh, both branches): a
        # fingerprint is a JSON string or it is nothing. Stringifying here would
        # take a hand-edited `last_diff_sha: 3` and hand it back as the real
        # string "3" — the value the readers reject, put into the shape they
        # accept, by this hook. Change one side of this and change the other.
        previous = state.get("last_diff_sha")
        state["prev_diff_sha"] = previous if isinstance(previous, str) else ""
        state["last_diff_sha"] = fingerprint
    else:
        forget_progress()

# open(path, "w") truncates first, and a Stop firing inside that window would
# read a zero-byte file, warn and give up the turn. Rename instead: a reader
# sees the old file or the new one, never half of one.
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(state, f)
    f.write("\n")
os.replace(tmp, path)
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
  give_up "payload carried no agent_transcript_path — verdict not recorded"
fi
if [ ! -f "$TRANSCRIPT" ]; then
  give_up "no readable agent transcript ('${TRANSCRIPT}') — verdict not recorded"
fi

ANSWER=$(mktemp "${TMPDIR:-/tmp}/record-verdict-XXXXXX") \
  || give_up "could not stage the reviewer's answer in ${TMPDIR:-/tmp}"
trap 'rm -f "$ANSWER"' EXIT
final_assistant_text "$TRANSCRIPT" > "$ANSWER" 2>/dev/null || {
  give_up "could not read the agent transcript $TRANSCRIPT"
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
    give_up "run_phase.py exited $PARSE_RC without a verdict — nothing recorded"
    ;;
esac

# Checked separately on purpose: the exit code and the word on stdout can fail
# independently. A parser that exits 0 having printed nothing (or something this
# hook does not know) must not reach record_state either.
case "$VERDICT" in
  APPROVE | CHANGES | BLOCK | UNKNOWN) ;;
  *)
    give_up "run_phase.py printed no recognisable verdict ('${VERDICT}') — nothing recorded"
    ;;
esac

# Parameter expansion, not dirname: self_dir() above avoids external commands so
# that a thin PATH cannot drown out this hook's one warning, and this line sits
# under the same rule. STATE_FILE always carries a directory component.
mkdir -p "${STATE_FILE%/*}" 2>/dev/null || true
record_state "$VERDICT" "$(diff_fingerprint)" || give_up "could not write $STATE_FILE"

exit 0
