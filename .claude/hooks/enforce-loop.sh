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

# --- payload + state read: jq -> python3 -> warn + exit 0 (as in announce-agent.sh) ---
# Both branches produce the same values in the same order, STATUS first, so that
# a malformed input is reported identically whichever reader the host has.
STATUS="ok"  # ok | bad-payload | bad-state
STOP_ACTIVE="false"
VERDICT=""
ATTEMPT=0
ENFORCED="false"
LAST_DIFF=""
PREV_DIFF=""
RECORD_FAILED="false"
RECORD_FAILED_REASON=""

# One rendering rule for the three keys this phase put under it —
# `last_diff_sha`, `prev_diff_sha`, `record_failed_reason` — written down once
# because its copies have already drifted apart three times in this phase
# alone. A value is a JSON string with newlines squashed to spaces, or it is
# nothing.
#
# `last_verdict` and `attempt` are read below WITHOUT this rule and still
# diverge between the two engines on `"BLOCK\n"`, `[]` and `{}`. That predates
# this phase, so it is not fixed here — but do not read the rule above as
# covering every key, because it does not, and the gap is in the two keys that
# decide the budget.
#
# The type test, and not `//`: jq falls through only on null and false while the
# python3 branch below also falls through on 0, [] and {} — and these values'
# *equality* is what decides an exit code and whether a mark is ever cleared. Do
# not put `tostring` back. It is what made a `last_diff_sha: 0` stop the loop
# under jq and re-dispatch under python3, and a `record_failed_reason: 0` be
# announced by jq and then never recognised by python3's compare-and-set, so
# the same two lines greeted every turn from then on.
#
# The squash is not cosmetic either: the python3 branch separates its fields by
# newlines, so one surviving inside a value would push every later field down a
# line and have this hook judge a budget the file never held.
#
# Every jq site that renders one of these keys goes through this variable, the
# compare-and-set below included — what a run announces and what it later
# matches have to be the same bytes. string_or_nothing() in the python3 branch
# is this same rule in the other engine: change one and change the other.
STATE_STRING_JQ='if (.[$k] | type) == "string" then .[$k] | gsub("[\n\r]"; " ") else "" end'

if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
    STATUS="bad-payload"
  elif ! jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
    STATUS="bad-state"
  else
    # `== true` and not a bare truth test: jq calls 0, "", [] and {} true where
    # python3 calls them false, and the branch a host happens to take must not
    # change an answer. Both flags are booleans, so anything else is a mangled
    # file and reads as unset.
    STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r 'if .stop_hook_active == true then "true" else "false" end')
    VERDICT=$(jq -r '.last_verdict // ""' "$STATE_FILE")
    ATTEMPT=$(jq -r '.attempt // 0' "$STATE_FILE")
    ENFORCED=$(jq -r 'if .enforced == true then "true" else "false" end' "$STATE_FILE")
    # record-verdict.sh's record_state holds the other half of the fingerprint
    # rule — it only ever writes a string there or leaves the key out, and it
    # refuses to stringify a corrupt one on the way — so a number, a list or a
    # boolean is a hand-edited or corrupt file, not a tree anybody measured.
    # Reading it as absent keeps the loop running, and that is the deliberately
    # safe direction: stopping a loop that should continue is enforcement
    # switching itself off, which is the failure this hook exists to prevent.
    LAST_DIFF=$(jq -r --arg k last_diff_sha "$STATE_STRING_JQ" "$STATE_FILE")
    PREV_DIFF=$(jq -r --arg k prev_diff_sha "$STATE_STRING_JQ" "$STATE_FILE")
    RECORD_FAILED=$(jq -r 'if .record_failed == true then "true" else "false" end' "$STATE_FILE")
    # Absent for this one means "announce the failure with no reason attached",
    # which is still the whole fact — the mark is what says a verdict went
    # unrecorded, and the reason only says which way.
    RECORD_FAILED_REASON=$(jq -r --arg k record_failed_reason "$STATE_STRING_JQ" "$STATE_FILE")
  fi
elif command -v python3 >/dev/null 2>&1; then
  OUT=$(printf '%s' "$INPUT" | python3 -c '
import json, sys

def load(opener):
    try:
        value = opener()
    except Exception:
        return None
    return value if isinstance(value, dict) else None

payload = load(lambda: json.load(sys.stdin))
state = load(lambda: json.load(open(sys.argv[1])))


def one_line(value):
    # A newline is the field separator below, so it cannot survive inside a
    # value: one in last_verdict would push attempt down a line and make this
    # branch read a budget the state file never held — an answer jq would not
    # have given.
    return str(value).replace("\n", " ").replace("\r", " ")


def string_or_nothing(value):
    # $STATE_STRING_JQ above, in the other engine, and it has to stay the same
    # rule: these are the values whose equality decides an exit code and whether
    # an announced mark is ever cleared. `or ""` is what it must not go back to;
    # that let 0, [] and {} through here while jq stringified them, so one reader
    # stopped the loop on a tree nobody measured and the other re-dispatched.
    # Absent means "not measured", which keeps the loop running — the safe
    # direction, because a loop stopped early is enforcement silently switching
    # off.
    return one_line(value) if isinstance(value, str) else ""


if payload is None:
    print("bad-payload")
elif state is None:
    print("bad-state")
else:
    print("ok")
# `is True`, not plain truthiness: jq above counts 0, "", [] and {} as true, and
# the two readers have to answer the same for every state file, not just tidy ones.
print("true" if (payload or {}).get("stop_hook_active") is True else "false")
print(one_line((state or {}).get("last_verdict") or ""))
print(one_line((state or {}).get("attempt") or 0))
print("true" if (state or {}).get("enforced") is True else "false")
print(string_or_nothing((state or {}).get("last_diff_sha")))
print(string_or_nothing((state or {}).get("prev_diff_sha")))
print("true" if (state or {}).get("record_failed") is True else "false")
print(string_or_nothing((state or {}).get("record_failed_reason")))
' "$STATE_FILE" 2>/dev/null) || OUT=""
  { IFS= read -r STATUS; IFS= read -r STOP_ACTIVE; IFS= read -r VERDICT
    IFS= read -r ATTEMPT; IFS= read -r ENFORCED
    IFS= read -r LAST_DIFF; IFS= read -r PREV_DIFF
    IFS= read -r RECORD_FAILED; IFS= read -r RECORD_FAILED_REASON; } <<< "$OUT"
  [ -z "$STATUS" ] && STATUS="bad-payload"
else
  warn "jq and python3 both missing — loop enforcement disabled"
  exit 0
fi

# Anything unreadable releases the turn. A session held by a hook that no
# longer knows what it is enforcing cannot be talked out of it — but say so,
# because a budget that quietly stopped being counted is the exact failure
# this hook was written to end.
case "$STATUS" in
  bad-payload)
    warn "unreadable Stop payload — loop budget not enforced for this turn"
    exit 0
    ;;
  bad-state)
    warn "unreadable $STATE_FILE — loop budget not enforced for this turn"
    exit 0
    ;;
esac

# Every in-place edit of the state file goes through here, so that the rule they
# all obey is written down once: read what is on disk now, change nothing unless
# it still matches what this run reacted to, and swap the file in whole.
#
# The mode is a literal argument, and the race test in tests/run-tests.sh keys
# its fake python3 on seeing "mark-enforced" there — it is how that test fires
# exactly when the enforced mark is about to be written, and not on the hook's
# other python3 calls. Passing the mode through stdin or an environment variable
# would leave that seam unwritable, and the race it pins (a verdict landing
# between this hook's read and its mark) is the one that switches enforcement
# off in a live loop.
state_edit() {  # mark-enforced <verdict> <attempt> | clear-record-failure <reason>
  # python3 is the in-place JSON editor this hook prefers. Where it is missing
  # no mark is written and enforcement degrades to what it did before
  # consume-once existed: react on every turn until a new verdict lands. Loud
  # and wrong beats quiet and off.
  if ! command -v python3 >/dev/null 2>&1; then
    # ...except for this one mark, where that degradation has no end. A host
    # with jq and no python3 cannot record a verdict at all — record-verdict.sh
    # needs python3 to parse one — so nothing will ever land a newer verdict to
    # displace a record_failed left there, and the announcement below would
    # repeat on every turn for good. jq cannot edit in place, but it can render
    # the whole file to a temp name that gets renamed over.
    #
    # Only this mode. mark-enforced's compare-and-set spans two values whose jq
    # rendering would have to match python's on every shape a state file can
    # hold, and that pair of renderings has already drifted apart twice in the
    # fingerprint readers. Its degradation stays bounded on its own terms: a
    # verdict re-blocks, it does not accumulate.
    command -v jq >/dev/null 2>&1 || return 0
    [ "$1" = "clear-record-failure" ] || return 0
    local tmp="$STATE_FILE.$$.tmp"  # a name record-verdict.sh cannot be holding open
    # The same compare-and-set the python3 branch below explains: clear only the
    # failure this run announced, so one that landed after the read survives.
    # Through $STATE_STRING_JQ, because $reason arrived from a reader that used
    # it: a clear that renders the value on disk any other way cannot match the
    # mark its own hook just announced, and a mark that cannot be matched is
    # announced on every turn for good.
    jq --arg reason "${2-}" --arg k record_failed_reason "
      if (.record_failed == true and ($STATE_STRING_JQ) == \$reason)
      then del(.record_failed, .record_failed_reason)
      else . end" "$STATE_FILE" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    return 0
  fi
  python3 - "$1" "$STATE_FILE" "${2-}" "${3-}" <<'PY' 2>/dev/null || true
import json, os, sys

mode, path = sys.argv[1], sys.argv[2]
with open(path) as f:
    state = json.load(f)

if mode == "mark-enforced":
    verdict, attempt = sys.argv[3], sys.argv[4]
    # record-verdict.sh may have written a newer verdict since this hook read
    # the file — SubagentStop and Stop are separate processes and the reviewer
    # runs as a background teammate, so nothing orders them. Stamping that one
    # spent would leave a verdict nobody reacted to already consumed, and the
    # next Stop would release the turn: enforcement silently off in a live loop.
    # Only stamp the verdict this run actually answered; a newer one stays armed
    # for its own turn. Do not simplify this back to "set enforced on whatever
    # is on disk".
    if (str(state.get("last_verdict") or "") != verdict
            or str(state.get("attempt") or 0) != attempt):
        raise SystemExit(0)
    state["enforced"] = True
elif mode == "clear-record-failure":
    reason = sys.argv[3]
    # Same rule, same reason: a failure that landed after the read has not been
    # announced to anybody. Clearing it would swallow it. Matching on the reason
    # is what makes a *different* later failure survive this — an identical one
    # is a message the user just read.
    #
    # Rendered the way the reader that produced `reason` rendered it — a string
    # with newlines squashed, or nothing (string_or_nothing() and
    # $STATE_STRING_JQ at the top of this file, and note that on an ordinary host
    # the reader was jq and this is python3). `str(... or "")` is what it must
    # not go back to: that read a `record_failed_reason: 0` as "" while jq had
    # just announced "0", so the mark was never cleared and the same two lines
    # greeted every turn after it.
    existing = state.get("record_failed_reason")
    if not isinstance(existing, str):
        existing = ""
    if (state.get("record_failed") is not True
            or existing.replace("\n", " ").replace("\r", " ") != reason):
        raise SystemExit(0)
    state.pop("record_failed", None)
    state.pop("record_failed_reason", None)
else:
    raise SystemExit(0)

tmp = "%s.%d.tmp" % (path, os.getpid())  # a name record-verdict.sh cannot be holding open
with open(tmp, "w") as f:
    json.dump(state, f)
    f.write("\n")
os.replace(tmp, path)  # a reader sees the old file or the new one, never half of one
PY
}

# Marks the verdict spent. Called on the reaction paths below and nowhere else,
# so the mark only ever follows something the user actually saw.
mark_enforced() {  # <verdict> <attempt>: the ones this run actually reacted to
  state_edit mark-enforced "$1" "$2"
}

# A reviewer ran and record-verdict.sh could not write down what it decided. The
# budget was not counted for that cycle and nothing downstream can recover it,
# so this is reported and the turn is released: re-dispatching a coder does not
# repair a parser, and the previous verdict was spent long ago. Announced once,
# by the same "one reaction, then consumed" rule the verdict itself follows.
#
# Before the attempt guards on purpose — this fact does not depend on the
# counter, and a state file with a broken attempt is exactly the kind that would
# otherwise swallow it.
if [ "$RECORD_FAILED" = "true" ]; then
  state_edit clear-record-failure "$RECORD_FAILED_REASON"
  echo "[enforce-loop] 리뷰어 판정이 기록되지 않았습니다: ${RECORD_FAILED_REASON}"
  echo "이번 사이클은 루프 예산에 세어지지 않았습니다. 자동으로 고칠 수 있는 문제가 아니니, 훅과 파서 상태를 사람이 확인하세요."
  exit 0
fi

# Valid JSON can still hold an uncountable attempt. Left alone it reaches
# `[ "$ATTEMPT" -ge ... ]`, where bash's own error makes the comparison false
# and the turn gets blocked on a number nobody can count.
case "$ATTEMPT" in
  '' | *[!0-9]*)
    warn "attempt in $STATE_FILE is not a number ('$ATTEMPT') — loop budget not enforced"
    exit 0
    ;;
esac

# All digits is not yet countable. `[ n -ge 3 ]` compares as a signed 64-bit
# integer and a longer number makes the test itself die; a dead test is false,
# so the exhaustion branch is skipped and the turn is held on a number nobody
# can count — with bash's own error on stderr next to our warning. The real
# counter never passes 3, so anything this long is a corrupt file, not a budget.
if [ "${#ATTEMPT}" -gt 9 ]; then
  warn "attempt in $STATE_FILE is out of range ('$ATTEMPT') — loop budget not enforced"
  exit 0
fi

# This turn only exists because a Stop hook blocked the previous one. Blocking
# it again would re-block our own continuation on every turn; Claude Code caps
# that at 8 consecutive blocks, but the budget of 3 is supposed to bite first.
[ "$STOP_ACTIVE" = "true" ] && exit 0

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

# One verdict buys one reaction — either a re-dispatch or the hand-over below,
# whichever this state calls for. Nothing deletes loop-state.json and attempt
# only grows when a reviewer runs, so a loop the user walked away from would
# otherwise sit on disk reacting to itself forever: blocking the end of every
# future turn in every future session over a phase nobody is working on, or, once
# the budget is spent, printing a hand-over banner on every message the user
# sends. A live loop never notices: record-verdict.sh writes a fresh, unspent
# verdict on every cycle.
[ "$ENFORCED" = "true" ] && exit 0

# Budget spent: let the turn end, because three more machine attempts will not
# find what three already missed. Exit 0 here is "stop", not "passed" — the
# message on stdout is what keeps it from reading as a clean finish.
if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
  mark_enforced "$VERDICT" "$ATTEMPT"  # this banner is the one reaction this verdict pays for
  echo "[enforce-loop] 자동 수정 루프 ${ATTEMPT}/${MAX_ATTEMPTS} 소진 — 마지막 리뷰 판정은 ${VERDICT} 입니다."
  echo "성공이 아닙니다. 사람 개입이 필요합니다: 리뷰 findings 를 직접 확인하고 범위를 다시 정하세요."
  exit 0
fi

# Budget left, but the tree is the one the last cycle was reviewed on: whatever
# the coder did between the two reviews, none of it reached a file. The
# remaining attempts would buy identical cycles, so spend none of them.
#
# A floor, not a net. record-verdict.sh fingerprints HEAD plus tracked and
# untracked content, so a coder that only added a test file, or only edited a
# file it never added, does not look stalled here. Nothing about this decides a
# phase is fine —
# the judgement is still the reviewer's.
#
# Both fingerprints have to be present: an empty one means "not measured" (no
# git, no repo, or the very first cycle of a loop), and reading two unknowns as
# one unchanged tree would stop every loop on its first BLOCK.
if [ -n "$LAST_DIFF" ] && [ "$LAST_DIFF" = "$PREV_DIFF" ]; then
  mark_enforced "$VERDICT" "$ATTEMPT"  # stopping early is this verdict's one reaction
  echo "[enforce-loop] 무진전 중단 — 직전 사이클과 작업 트리가 동일합니다 (attempt ${ATTEMPT}/${MAX_ATTEMPTS}, 판정 ${VERDICT})." >&2
  echo "성공이 아닙니다. 사람 개입이 필요합니다: 같은 코드에 같은 리뷰가 반복될 뿐이니, findings 를 직접 확인하고 범위를 다시 정하세요."
  exit 0
fi

# Exit 2 on Stop = "do not stop, continue the conversation". stderr is what the
# model reads, so it has to be an instruction, not just a complaint.
mark_enforced "$VERDICT" "$ATTEMPT"  # this block is the one reaction this verdict pays for
{
  echo "[enforce-loop] Reviewer verdict ${VERDICT} — the phase is not done (attempt ${ATTEMPT}/${MAX_ATTEMPTS})."
  echo "Re-dispatch whichever agent the findings call for — coder for code, documenter for docs — in fix mode, then re-run the reviewer."
} >&2
exit 2
