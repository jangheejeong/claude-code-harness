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
# Both branches produce the same four values, STATUS first, so that a malformed
# input is reported identically whichever reader the host happens to have.
STATUS="ok"  # ok | bad-payload | bad-state
STOP_ACTIVE="false"
VERDICT=""
ATTEMPT=0
if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
    STATUS="bad-payload"
  elif ! jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
    STATUS="bad-state"
  else
    STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r 'if .stop_hook_active then "true" else "false" end')
    VERDICT=$(jq -r '.last_verdict // ""' "$STATE_FILE")
    ATTEMPT=$(jq -r '.attempt // 0' "$STATE_FILE")
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

if payload is None:
    print("bad-payload")
elif state is None:
    print("bad-state")
else:
    print("ok")
print("true" if (payload or {}).get("stop_hook_active") else "false")
print((state or {}).get("last_verdict") or "")
print((state or {}).get("attempt") or 0)
' "$STATE_FILE" 2>/dev/null) || OUT=""
  { IFS= read -r STATUS; IFS= read -r STOP_ACTIVE; IFS= read -r VERDICT; IFS= read -r ATTEMPT; } <<< "$OUT"
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

# Budget spent: let the turn end, because three more machine attempts will not
# find what three already missed. Exit 0 here is "stop", not "passed" — the
# message on stdout is what keeps it from reading as a clean finish.
if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
  echo "[enforce-loop] 자동 수정 루프 ${ATTEMPT}/${MAX_ATTEMPTS} 소진 — 마지막 리뷰 판정은 ${VERDICT} 입니다."
  echo "성공이 아닙니다. 사람 개입이 필요합니다: 리뷰 findings 를 직접 확인하고 범위를 다시 정하세요."
  exit 0
fi

# Exit 2 on Stop = "do not stop, continue the conversation". stderr is what the
# model reads, so it has to be an instruction, not just a complaint.
{
  echo "[enforce-loop] Reviewer verdict ${VERDICT} — the phase is not done (attempt ${ATTEMPT}/${MAX_ATTEMPTS})."
  echo "Re-dispatch the coder in fix mode with the reviewer's findings, then re-run the reviewer."
} >&2
exit 2
