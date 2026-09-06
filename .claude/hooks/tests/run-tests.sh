#!/bin/bash
# Self-contained test suite for the harness hooks.
# Run: bash .claude/hooks/tests/run-tests.sh
# Each case pipes synthetic hook-input JSON into a hook and asserts the exit
# code (0 = allow, 2 = deny). Prints PASS/FAIL per case and a final count;
# exits non-zero if any case fails.

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

report() {  # <0=ok|nonzero=fail> <hook-label> <description>
  if [ "$1" -eq 0 ]; then
    PASS=$((PASS + 1)); printf 'PASS  [%s] %s\n' "$2" "$3"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  [%s] %s\n' "$2" "$3"
  fi
}

run_case() {  # <hook-file> <expected-exit> <description> <json>
  local hook="$1" expected="$2" desc="$3" json="$4"
  local actual=0
  printf '%s' "$json" | bash "$HOOKS_DIR/$hook" >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    report 0 "$hook" "$desc"
  else
    report 1 "$hook" "$desc (expected exit $expected, got $actual)"
  fi
}

bash_json() {  # PreToolUse(Bash) payload for a command (escapes \ and ")
  local c="$1"
  c="${c//\\/\\\\}"
  c="${c//\"/\\\"}"
  printf '{"tool_input":{"command":"%s"}}' "$c"
}

path_json() {  # PreToolUse/PostToolUse(Edit|Write) payload for a file path
  printf '{"tool_input":{"file_path":"%s"}}' "$1"
}

B=block-destructive.sh
P=protect-secrets.sh
L=post-edit-lint.sh
A=announce-agent.sh
R=record-verdict.sh
E=enforce-loop.sh

# ---------- block-destructive.sh : deny ----------
run_case "$B" 2 "rm -rf /"                          "$(bash_json 'rm -rf /')"
run_case "$B" 2 "rm -rf /*"                         "$(bash_json 'rm -rf /*')"
run_case "$B" 2 "rm -rf /etc"                       "$(bash_json 'rm -rf /etc')"
run_case "$B" 2 "rm -rf /etc/nginx (under system)"  "$(bash_json 'rm -rf /etc/nginx')"
run_case "$B" 2 "first rm in chain (;)"             "$(bash_json 'rm -rf /etc ; rm -rf node_modules')"
run_case "$B" 2 "second rm in chain (&&)"           "$(bash_json 'rm -rf node_modules && rm -rf /usr/local')"
run_case "$B" 2 "rm after pipe"                     "$(bash_json 'true | rm -rf /var/log')"
run_case "$B" 2 "absolute-path /bin/rm"             "$(bash_json '/bin/rm -rf /')"
run_case "$B" 2 "separated flags rm -r -f"          "$(bash_json 'rm -r -f /etc')"
run_case "$B" 2 "long flags --recursive --force"    "$(bash_json 'rm --recursive --force /var')"
run_case "$B" 2 "quoted broad target rm -rf \"/\""  "$(bash_json 'rm -rf "/"')"
run_case "$B" 2 "rm -rf ~"                          "$(bash_json 'rm -rf ~')"
run_case "$B" 2 "rm -rf \$HOME"                     "$(bash_json 'rm -rf $HOME')"
run_case "$B" 2 "git push --force"                  "$(bash_json 'git push --force')"
run_case "$B" 2 "git push -f"                       "$(bash_json 'git push -f origin main')"
run_case "$B" 2 "git push --force-with-lease"       "$(bash_json 'git push --force-with-lease origin main')"
run_case "$B" 2 "git -C <path> push --force"        "$(bash_json 'git -C /tmp/x push --force')"
run_case "$B" 2 "plus-refspec force push"           "$(bash_json 'git push origin +main:main')"
run_case "$B" 2 "force push after && chain"         "$(bash_json 'git add . && git push -f')"
run_case "$B" 2 "git reset --hard origin/<branch>"  "$(bash_json 'git reset --hard origin/main')"
run_case "$B" 2 "dd of=/dev/disk0"                  "$(bash_json 'dd if=/dev/zero of=/dev/disk0')"
run_case "$B" 2 "dd of=/dev/rdisk0 (macOS raw)"     "$(bash_json 'dd if=x.img of=/dev/rdisk0')"

# ---------- block-destructive.sh : allow / false-positive guards ----------
run_case "$B" 0 "rm -rf node_modules"               "$(bash_json 'rm -rf node_modules')"
run_case "$B" 0 "rm -rf ./build && npm install"     "$(bash_json 'rm -rf ./build && npm install')"
run_case "$B" 0 "rm -rf /development (no /dev FP)"  "$(bash_json 'rm -rf /development')"
run_case "$B" 0 "rm -rf /varchive (no /var FP)"     "$(bash_json 'rm -rf /varchive')"
run_case "$B" 0 "rm -rf under /Users is fine"       "$(bash_json 'rm -rf /Users/me/proj/build')"
run_case "$B" 0 "rm without -rf"                    "$(bash_json 'rm file.txt')"
run_case "$B" 0 "rm -rf with stdout redirect"       "$(bash_json 'rm -rf build > /dev/null')"
run_case "$B" 0 "rm -rf with stderr redirect"       "$(bash_json 'rm -rf build 2>/dev/null')"
run_case "$B" 0 "grep -rf is not rm"                "$(bash_json 'grep -rf patterns.txt /etc')"
run_case "$B" 0 "quoted rm string in echo"          "$(bash_json 'echo "rm -rf /"')"
run_case "$B" 0 "git push without force"            "$(bash_json 'git push origin main')"
run_case "$B" 0 "git push -u (no force)"            "$(bash_json 'git push -u origin feature')"
run_case "$B" 0 "git reset --hard HEAD~1"           "$(bash_json 'git reset --hard HEAD~1')"
run_case "$B" 0 "dd to a regular file"              "$(bash_json 'dd if=a.img of=b.img')"
run_case "$B" 0 "plain command"                     "$(bash_json 'ls -la')"
run_case "$B" 0 "empty payload"                     '{}'

# D2 protocol: deny reason goes to stderr, stdout stays empty
ERR_FILE=$(mktemp /tmp/hooktest-err-XXXXXX)
OUT=$(printf '%s' "$(bash_json 'rm -rf /')" | bash "$HOOKS_DIR/$B" 2>"$ERR_FILE")
RC=$?
ERR=$(cat "$ERR_FILE"); rm -f "$ERR_FILE"
if [ "$RC" -eq 2 ] && [ -z "$OUT" ] && [ -n "$ERR" ]; then
  report 0 "$B" "deny protocol: exit 2 + reason on stderr, no stdout"
else
  report 1 "$B" "deny protocol: exit 2 + reason on stderr, no stdout (rc=$RC out='$OUT')"
fi

# D3 protocol: no jq AND no python3 -> fail-open with a LOUD warning (exit 0)
ERR=$(printf '%s' "$(bash_json 'rm -rf /')" | env PATH=/var/empty /bin/bash "$HOOKS_DIR/$B" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -qi 'WARNING'; then
  report 0 "$B" "fail-open without jq/python3 prints a warning"
else
  report 1 "$B" "fail-open without jq/python3 prints a warning (rc=$RC)"
fi

# ---------- protect-secrets.sh : deny ----------
run_case "$P" 2 ".env"                              "$(path_json '/proj/.env')"
run_case "$P" 2 ".env.local"                        "$(path_json '/proj/.env.local')"
run_case "$P" 2 ".envrc"                            "$(path_json '/proj/.envrc')"
run_case "$P" 2 "server.pem"                        "$(path_json '/proj/certs/server.pem')"
run_case "$P" 2 "private.key"                       "$(path_json '/proj/private.key')"
run_case "$P" 2 "cert.p12"                          "$(path_json '/proj/cert.p12')"
run_case "$P" 2 "AuthKey.p8"                        "$(path_json '/proj/AuthKey_ABC123.p8')"
run_case "$P" 2 "release.keystore"                  "$(path_json '/proj/android/release.keystore')"
run_case "$P" 2 "id_rsa"                            "$(path_json '/proj/deploy/id_rsa')"
run_case "$P" 2 "id_ed25519"                        "$(path_json '/home/u/.ssh/id_ed25519')"
run_case "$P" 2 ".npmrc"                            "$(path_json '/proj/.npmrc')"
run_case "$P" 2 ".pypirc"                           "$(path_json '/home/u/.pypirc')"
run_case "$P" 2 ".htpasswd"                         "$(path_json '/srv/www/.htpasswd')"
run_case "$P" 2 "credentials.json"                  "$(path_json '/proj/gcp/credentials.json')"
run_case "$P" 2 "client_secret.json"                "$(path_json '/proj/client_secret.json')"
run_case "$P" 2 "api-token.yaml"                    "$(path_json '/proj/config/api-token.yaml')"
run_case "$P" 2 ".aws-credentials (dotfile)"        "$(path_json '/home/u/.aws-credentials')"
run_case "$P" 2 ".mcp.json"                         "$(path_json '/proj/.mcp.json')"

# ---------- protect-secrets.sh : allow / false-positive guards ----------
run_case "$P" 0 "token_service.py"                  "$(path_json '/proj/src/token_service.py')"
run_case "$P" 0 "tokenizer.py"                      "$(path_json '/proj/src/tokenizer.py')"
run_case "$P" 0 "design-tokens.css"                 "$(path_json '/proj/web/src/styles/design-tokens.css')"
run_case "$P" 0 "tokens.ts"                         "$(path_json '/proj/config/tokens.ts')"
run_case "$P" 0 "secretary.py"                      "$(path_json '/proj/app/secretary.py')"
run_case "$P" 0 "secret-rotation.md (doc)"          "$(path_json '/proj/docs/secret-rotation.md')"
run_case "$P" 0 "api-tokens.txt (doc)"              "$(path_json '/proj/notes/api-tokens.txt')"
run_case "$P" 0 ".env.example (template)"           "$(path_json '/proj/.env.example')"
run_case "$P" 0 "ordinary source file"              "$(path_json '/proj/src/main.py')"
run_case "$P" 0 "empty payload"                     '{}'

# ---------- post-edit-lint.sh ----------
run_case "$L" 0 "non-python file: silent skip"      "$(path_json '/tmp/whatever.txt')"
run_case "$L" 0 "empty payload: silent skip"        '{}'
TMP_PY="/tmp/hooktest-$$.py"
printf 'x  =  1\n' > "$TMP_PY"
run_case "$L" 0 "python file: format + exit 0"      "$(path_json "$TMP_PY")"
rm -f "$TMP_PY"

# ---------- announce-agent.sh ----------
TMP_PROJ=$(mktemp -d /tmp/hooktest-proj-XXXXXX)
export CLAUDE_PROJECT_DIR="$TMP_PROJ"
run_case "$A" 0 "SubagentStart (coder)"  '{"hook_event_name":"SubagentStart","agent_type":"coder","session_id":"s1","cwd":"/tmp"}'
run_case "$A" 0 "SubagentStop (reviewer)" '{"hook_event_name":"SubagentStop","agent_type":"reviewer","effort":{"level":"high"}}'
run_case "$A" 0 "garbage input still exits 0"       'not json at all'
if grep -q 'SubagentStart  coder' "$TMP_PROJ/.claude/notes/agent-activity.log" 2>/dev/null; then
  report 0 "$A" "activity log written under \$CLAUDE_PROJECT_DIR"
else
  report 1 "$A" "activity log written under \$CLAUDE_PROJECT_DIR"
fi
unset CLAUDE_PROJECT_DIR
rm -rf "$TMP_PROJ"

# ---------- run_phase.py --parse-verdict ----------
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
REVIEWER_MD="$REPO_ROOT/.claude/agents/reviewer.md"
RUN_PHASE="$REPO_ROOT/scripts/harness/run_phase.py"

cmd_case() {  # <expected-exit> <expected-stdout> <description> <cmd> [args...]
  local expected="$1" want="$2" desc="$3"; shift 3
  local out actual=0
  out=$("$@" 2>/dev/null) || actual=$?
  if [ "$actual" -eq "$expected" ] && [ "$out" = "$want" ]; then
    report 0 "run_phase.py" "$desc"
  else
    report 1 "run_phase.py" "$desc (expected exit $expected/'$want', got $actual/'$out')"
  fi
}

verdict_case() {  # <expected-exit> <expected-stdout> <description> <log-body>
  local log
  log=$(mktemp /tmp/hooktest-verdict-XXXXXX)
  printf '%s\n' "$4" > "$log"
  cmd_case "$1" "$2" "$3" python3 "$RUN_PHASE" --parse-verdict "$log"
  rm -f "$log"
}

# The verdict tag must be the template's LAST line so a hook can read the
# reviewer's conclusion by tailing the log instead of re-parsing the review.
VERDICT_TEMPLATE_LINE='<verdict>APPROVE|REQUEST CHANGES|BLOCK</verdict>'
TAG_LINE=$(grep -nxF "$VERDICT_TEMPLATE_LINE" "$REVIEWER_MD" | head -1 | cut -d: -f1)
NEXT_LINE=$(awk -v n="$((${TAG_LINE:-0} + 1))" 'NR==n' "$REVIEWER_MD")
if [ -n "$TAG_LINE" ] && [ "$NEXT_LINE" = '```' ]; then
  report 0 "reviewer.md" "verdict tag is the last line of the output template"
else
  report 1 "reviewer.md" "verdict tag is the last line of the output template (line='$TAG_LINE' next='$NEXT_LINE')"
fi

if grep -qF '### 결론' "$REVIEWER_MD" && grep -qF '### 판정 표' "$REVIEWER_MD" \
   && grep -qF '### Findings' "$REVIEWER_MD"; then
  report 0 "reviewer.md" "결론 / 판정 표 / Findings sections intact"
else
  report 1 "reviewer.md" "결론 / 판정 표 / Findings sections intact"
fi

verdict_case 0 "APPROVE" "APPROVE -> stdout APPROVE, exit 0" \
  '## Review: Phase 1

### 결론
APPROVE — 이슈 없음

<verdict>APPROVE</verdict>'

# Tag keeps the reviewer's own wording; the parsed value is normalized.
verdict_case 4 "CHANGES" "REQUEST CHANGES -> stdout CHANGES, exit 4" \
  '### 결론
REQUEST CHANGES — 인수 기준 1건 미달

<verdict>REQUEST CHANGES</verdict>'

verdict_case 5 "BLOCK" "BLOCK -> stdout BLOCK, exit 5" \
  '### 결론
BLOCK — 하드코딩된 토큰

<verdict>BLOCK</verdict>'

# A reviewer may quote the tag inside its findings; only the one on the log's
# last non-empty line counts as its judgement.
verdict_case 5 "BLOCK" "multiple tags -> the one on the last line wins" \
  '#### [NEW][CHANGES] run_phase.py:12 — 태그 누락
개선안: 마지막 줄에 <verdict>APPROVE</verdict> 를 붙일 것

### 결론
BLOCK

<verdict>BLOCK</verdict>'

# Backward compatibility: an agent that never learned the tag must not be
# treated as a failure — the harness falls back to its pre-tag behavior.
verdict_case 0 "UNKNOWN" "no tag -> stdout UNKNOWN, exit 0" \
  '### 결론
APPROVE — 태그를 모르는 구버전 리뷰어 출력'

# A wrong path is a caller bug (exit 1), and must read as one — a Python
# traceback would be indistinguishable from the script itself crashing.
MISSING_ERR=$(mktemp /tmp/hooktest-err-XXXXXX)
MISSING_OUT=$(python3 "$RUN_PHASE" --parse-verdict /nonexistent/review.log 2>"$MISSING_ERR")
RC=$?
ERR=$(cat "$MISSING_ERR"); rm -f "$MISSING_ERR"
if [ "$RC" -eq 1 ] && [ -z "$MISSING_OUT" ] && printf '%s' "$ERR" | grep -q 'ERROR' \
   && ! printf '%s' "$ERR" | grep -q 'Traceback'; then
  report 0 "run_phase.py" "missing log file -> exit 1 with a readable error"
else
  report 1 "run_phase.py" "missing log file -> exit 1 with a readable error (rc=$RC out='$MISSING_OUT')"
fi

# Parsing is pure: a hook may call it on a machine that has no `claude` CLI.
# PATH is emptied rather than mangled, so resolve the real interpreter first
# (a pyenv shim is a shell script and would not survive an empty PATH).
REAL_PY=$(python3 -c 'import sys; print(sys.executable)')
VERDICT_LOG=$(mktemp /tmp/hooktest-verdict-XXXXXX)
printf '<verdict>APPROVE</verdict>\n' > "$VERDICT_LOG"
cmd_case 0 "APPROVE" "no claude CLI on PATH -> still parses (not exit 2)" \
  env PATH=/var/empty "$REAL_PY" "$RUN_PHASE" --parse-verdict "$VERDICT_LOG"
rm -f "$VERDICT_LOG"

# ---------- run_phase.py --parse-verdict : edge cases ----------
# The reviewer's own template line is a literal
# `<verdict>APPROVE|REQUEST CHANGES|BLOCK</verdict>`. If that parsed, a
# reviewer echoing its instructions back would fabricate a verdict out of thin
# air — and reviewer.md is exactly the kind of file that ends up quoted in a log.
cmd_case 0 "UNKNOWN" "reviewer.md itself parses as UNKNOWN (no self-match)" \
  python3 "$RUN_PHASE" --parse-verdict "$REVIEWER_MD"

verdict_case 0 "UNKNOWN" "bare template line is not a verdict" \
  "$VERDICT_TEMPLATE_LINE"

verdict_case 5 "BLOCK" "template line above a real verdict -> real one wins" \
  "$VERDICT_TEMPLATE_LINE
<verdict>BLOCK</verdict>"

verdict_case 5 "BLOCK" "tag fenced above a real verdict -> the last line wins" \
  '리뷰어는 이렇게 끝내야 한다:
```
<verdict>APPROVE</verdict>
```

<verdict>BLOCK</verdict>'

# An empty log is what a killed or redirected run leaves behind. It must read
# as "no verdict", never as a verdict.
EMPTY_LOG=$(mktemp /tmp/hooktest-verdict-XXXXXX)
: > "$EMPTY_LOG"
cmd_case 0 "UNKNOWN" "empty file -> UNKNOWN, exit 0" \
  python3 "$RUN_PHASE" --parse-verdict "$EMPTY_LOG"
rm -f "$EMPTY_LOG"

verdict_case 0 "UNKNOWN" "whitespace-only file -> UNKNOWN, exit 0" \
  "$(printf ' \n\t\n')"

# The tag is typed by a language model, not emitted by a serializer, so case
# and padding drift. Anything that unambiguously names one of the three
# verdicts counts.
verdict_case 5 "BLOCK"   "lowercase value"                 '<verdict>block</verdict>'
verdict_case 5 "BLOCK"   "uppercase tag name"              '<VERDICT>BLOCK</VERDICT>'
verdict_case 5 "BLOCK"   "value padded with spaces"        '<verdict>  BLOCK  </verdict>'
verdict_case 4 "CHANGES" "runs of spaces inside the value" '<verdict>REQUEST   CHANGES</verdict>'
verdict_case 5 "BLOCK"   "value split across newlines"     '<verdict>
BLOCK
</verdict>'

# A near-miss is not rounded to the nearest verdict. UNKNOWN reopens the
# pre-tag behavior, which is the safe direction for a garbled tag — inventing
# a BLOCK from "BLOCKED" would stall the loop on a typo.
verdict_case 0 "UNKNOWN" "BLOCKED is not BLOCK"      '<verdict>BLOCKED</verdict>'
verdict_case 0 "UNKNOWN" "an invented verdict word"  '<verdict>LGTM</verdict>'

# Logs are raw `claude` stdout: a truncated write or a stray escape sequence
# leaves bytes that are not valid UTF-8. Decoding must absorb them, not raise.
BIN_LOG=$(mktemp /tmp/hooktest-verdict-XXXXXX)
printf '\xff\xfe truncated \x00\x80\n<verdict>BLOCK</verdict>\n' > "$BIN_LOG"
cmd_case 5 "BLOCK" "undecodable bytes in the log -> still parses" \
  python3 "$RUN_PHASE" --parse-verdict "$BIN_LOG"
rm -f "$BIN_LOG"

verdict_case 5 "BLOCK" "unicode / emoji / RTL in the review body" \
  '### 결론
BLOCK — 하드코딩된 토큰 🚨 مرحبا

<verdict>BLOCK</verdict>'

# Same contract as the missing-file case: any unreadable path is a caller bug
# that must exit 1 with a readable line, because Phase 2 hooks will branch on
# `case $?` and a traceback (also exit 1) would be indistinguishable.
read_error_case() {  # <description> <path>
  local desc="$1" path="$2" out msg err rc=0
  err=$(mktemp /tmp/hooktest-err-XXXXXX)
  out=$(python3 "$RUN_PHASE" --parse-verdict "$path" 2>"$err") || rc=$?
  msg=$(cat "$err"); rm -f "$err"
  if [ "$rc" -eq 1 ] && [ -z "$out" ] && printf '%s' "$msg" | grep -q 'ERROR' \
     && ! printf '%s' "$msg" | grep -q 'Traceback'; then
    report 0 "run_phase.py" "$desc"
  else
    report 1 "run_phase.py" "$desc (rc=$rc out='$out')"
  fi
}

read_error_case "directory instead of a file -> exit 1" "$HOOKS_DIR"

# chmod 000 does not stop root, so the case would assert nothing there.
if [ "$(id -u)" -eq 0 ]; then
  report 0 "run_phase.py" "unreadable file -> exit 1 (skipped: running as root)"
else
  NOPERM_LOG=$(mktemp /tmp/hooktest-verdict-XXXXXX)
  printf '<verdict>BLOCK</verdict>\n' > "$NOPERM_LOG"
  chmod 000 "$NOPERM_LOG"
  read_error_case "unreadable file -> exit 1, not a traceback" "$NOPERM_LOG"
  chmod 600 "$NOPERM_LOG"; rm -f "$NOPERM_LOG"
fi

# ---------- run_phase.py --parse-verdict : the tag must be on the last line ----------
# A quoted tag must not pass for a judgement, so only the last non-empty line
# counts. That trade has its own silent failure — if the CLI ever appends
# anything after the tag, every verdict turns UNKNOWN and loop enforcement goes
# off without a sound — so these cases assert stderr, not just the exit code.
verdict_file_case() {  # <expected-exit> <expected-stdout> <warn|quiet> <desc> <log-path>
  local expected="$1" want="$2" mode="$3" desc="$4" path="$5"
  local err out msg rc=0 ok=0
  err=$(mktemp /tmp/hooktest-err-XXXXXX)
  out=$(python3 "$RUN_PHASE" --parse-verdict "$path" 2>"$err") || rc=$?
  msg=$(cat "$err"); rm -f "$err"
  [ "$rc" -eq "$expected" ] && [ "$out" = "$want" ] || ok=1
  printf '%s' "$msg" | grep -q 'Traceback' && ok=1
  case "$mode" in
    warn)  printf '%s' "$msg" | grep -qi 'WARNING' || ok=1 ;;
    quiet) [ -z "$msg" ] || ok=1 ;;
  esac
  if [ "$ok" -eq 0 ]; then
    report 0 "run_phase.py" "$desc"
  else
    report 1 "run_phase.py" "$desc (want exit $expected/'$want'/$mode, got $rc/'$out'/err='$msg')"
  fi
}

verdict_placement_case() {  # <expected-exit> <expected-stdout> <warn|quiet> <desc> <log-body>
  local log
  log=$(mktemp /tmp/hooktest-verdict-XXXXXX)
  printf '%s\n' "$5" > "$log"
  verdict_file_case "$1" "$2" "$3" "$4" "$log"
  rm -f "$log"
}

# A tag that is already where reviewer.md tells the reviewer to put it keeps
# parsing exactly as before, and says nothing on stderr.
verdict_placement_case 0 "APPROVE" quiet "tag on the last line -> APPROVE, exit 0, no warning" \
  '### 결론
APPROVE — 이슈 없음

<verdict>APPROVE</verdict>'

verdict_placement_case 4 "CHANGES" quiet "tag on the last line -> CHANGES, exit 4, no warning" \
  '### 결론
REQUEST CHANGES — 인수 기준 1건 미달

<verdict>REQUEST CHANGES</verdict>'

verdict_placement_case 5 "BLOCK" quiet "tag on the last line -> BLOCK, exit 5, no warning" \
  '### 결론
BLOCK — 하드코딩된 토큰

<verdict>BLOCK</verdict>'

# "Last line" means last *non-empty* line: a log is a redirected stdout stream,
# and a trailing newline or a stray space after the tag is not the agent
# forgetting to judge.
TRAIL_LOG=$(mktemp /tmp/hooktest-verdict-XXXXXX)
printf '### 결론\nBLOCK\n\n<verdict>BLOCK</verdict>   \n\n\t\n\n' > "$TRAIL_LOG"
verdict_file_case 5 "BLOCK" quiet "trailing blank lines and spaces after the tag -> still parses" \
  "$TRAIL_LOG"
rm -f "$TRAIL_LOG"

# The case the rule exists for: the reviewer quoted the tag while writing up a
# finding and then never judged. Reading the quote as a judgement would hand
# Phase 2 an APPROVE that resets the retry budget for free.
verdict_placement_case 0 "UNKNOWN" warn "tag quoted mid-findings, none at the end -> UNKNOWN + warning" \
  '#### [NEW][CHANGES] run_phase.py:12 — 태그 누락
개선안: 마지막 줄에 <verdict>APPROVE</verdict> 를 붙일 것

### 결론
리뷰 계속'

verdict_placement_case 0 "UNKNOWN" warn "tag only inside a fenced block -> UNKNOWN + warning" \
  '리뷰어는 이렇게 끝내야 한다:
```
<verdict>BLOCK</verdict>
```
이상.'

# Quoting the tag and then judging properly is the normal case, not an
# anomaly. If it warned, every real review would carry a warning and the
# channel would stop meaning anything.
verdict_placement_case 5 "BLOCK" quiet "quoted tag above a real one -> last line wins, no warning" \
  '#### [NEW][CHANGES] run_phase.py:12 — 태그 누락
개선안: 마지막 줄에 <verdict>APPROVE</verdict> 를 붙일 것

### 결론
BLOCK

<verdict>BLOCK</verdict>'

# No tag at all is the pre-tag agent, which Phase 1 deliberately keeps working.
# Warning here would flag every legacy run as broken.
verdict_placement_case 0 "UNKNOWN" quiet "no tag anywhere -> UNKNOWN, exit 0, no warning" \
  '### 결론
APPROVE — 태그를 모르는 구버전 리뷰어 출력'

EMPTY_PLACEMENT_LOG=$(mktemp /tmp/hooktest-verdict-XXXXXX)
: > "$EMPTY_PLACEMENT_LOG"
verdict_file_case 0 "UNKNOWN" quiet "empty file -> UNKNOWN, exit 0, no warning" \
  "$EMPTY_PLACEMENT_LOG"
rm -f "$EMPTY_PLACEMENT_LOG"

verdict_placement_case 0 "UNKNOWN" quiet "whitespace-only file -> UNKNOWN, exit 0, no warning" \
  "$(printf ' \n\t\n')"

# The one log written by a real reviewer that this repo still has on disk. It
# quotes the tag mid-review and judges on its last line, so it exercises the
# rule end-to-end on output no test author shaped. .claude/notes/ is
# gitignored, so a fresh clone simply skips it.
REAL_REVIEW_LOG="$REPO_ROOT/.claude/notes/review-phase1-verdict.log"
if [ -f "$REAL_REVIEW_LOG" ]; then
  verdict_file_case 0 "APPROVE" quiet "real Phase 1 review log -> APPROVE, exit 0, no warning" \
    "$REAL_REVIEW_LOG"
else
  report 0 "run_phase.py" "real Phase 1 review log -> APPROVE (skipped: log not on disk)"
fi

# ---------- run_phase.py : usage errors exit 1, not 2 ----------
# argparse exits 2 on any usage error, which collides with "2 = claude CLI
# missing". A Phase 2 hook branching on `case $?` would read a typo as a
# missing CLI, so every usage error must come back as 1 = bad arguments.
usage_error_case() {  # <description> <arg>...
  local desc="$1"; shift
  local out msg err rc=0
  err=$(mktemp /tmp/hooktest-err-XXXXXX)
  out=$(python3 "$RUN_PHASE" "$@" 2>"$err") || rc=$?
  msg=$(cat "$err"); rm -f "$err"
  if [ "$rc" -eq 1 ] && printf '%s' "$msg" | grep -q 'ERROR' \
     && ! printf '%s' "$msg" | grep -q 'Traceback'; then
    report 0 "run_phase.py" "$desc"
  else
    report 1 "run_phase.py" "$desc (rc=$rc err='$msg')"
  fi
}

usage_error_case "--parse-verdict without a value -> exit 1" --parse-verdict
usage_error_case "missing required arguments -> exit 1" --subproject x
# Required args supplied, so the unknown flag is the only thing left to fail on.
usage_error_case "unknown flag -> exit 1" \
  --subproject x --phase 1 --agent coder --bogus

# The pre-scan parser knows only --parse-verdict, so its usage line used to
# hide every real option from whoever had just mistyped one.
PEEK_ERR=$(mktemp /tmp/hooktest-err-XXXXXX)
python3 "$RUN_PHASE" --parse-verdict >/dev/null 2>"$PEEK_ERR"
ERR=$(cat "$PEEK_ERR"); rm -f "$PEEK_ERR"
if printf '%s' "$ERR" | grep -q -- '--subproject' \
   && printf '%s' "$ERR" | grep -q -- '--parse-verdict'; then
  report 0 "run_phase.py" "pre-scan usage line shows both invocation forms"
else
  report 1 "run_phase.py" "pre-scan usage line shows both invocation forms (err='$ERR')"
fi

# --help is not a usage error: overriding error() must not swallow it.
HELP_OUT=$(python3 "$RUN_PHASE" --help 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$HELP_OUT" | grep -q -- '--parse-verdict'; then
  report 0 "run_phase.py" "--help -> exit 0 with the option list"
else
  report 1 "run_phase.py" "--help -> exit 0 with the option list (rc=$RC)"
fi

# ---------- run_phase.py : agent run reports the reviewer's verdict ----------
# The `claude` CLI exits 0 whatever the reviewer concluded, so a stub CLI is
# enough to pin the status line the harness derives from the run's log.
TMP_SUBPROJ=$(mktemp -d /tmp/hooktest-subproj-XXXXXX)
printf '# Plans\n' > "$TMP_SUBPROJ/Plans.md"

agent_run_case() {  # <expected-exit> <status-substring> <desc> <agent> <cli-exit> <cli-stdout>
  local expected="$1" want="$2" desc="$3" agent="$4" cli_exit="$5" cli_out="$6"
  local bin out actual=0
  bin=$(mktemp -d /tmp/hooktest-bin-XXXXXX)
  {
    printf '#!/bin/bash\n'
    printf "cat <<'CLAUDE_EOF'\n"
    printf '%s\n' "$cli_out"
    printf 'CLAUDE_EOF\n'
    printf 'exit %s\n' "$cli_exit"
  } > "$bin/claude"
  chmod +x "$bin/claude"
  out=$(PATH="$bin:$PATH" python3 "$RUN_PHASE" --subproject "$TMP_SUBPROJ" \
          --phase 999 --agent "$agent" 2>/dev/null) || actual=$?
  rm -rf "$bin"
  if [ "$actual" -eq "$expected" ] && printf '%s' "$out" | grep -qF "$want"; then
    report 0 "run_phase.py" "$desc"
  else
    report 1 "run_phase.py" "$desc (expected exit $expected + '$want', got $actual: $out)"
  fi
}

agent_run_case 5 "status=BLOCK" "reviewer BLOCK -> status=BLOCK, exit 5" reviewer 0 \
  '### 결론
BLOCK — 하드코딩된 토큰

<verdict>BLOCK</verdict>'
agent_run_case 0 "status=OK" "reviewer APPROVE -> status=OK, exit 0" reviewer 0 \
  '<verdict>APPROVE</verdict>'
agent_run_case 0 "status=OK" "coder success -> status=OK, exit 0 (no regression)" coder 0 \
  'phase done'
agent_run_case 3 "status=FAIL(7)" "agent failure -> status=FAIL(7), exit 3 (no regression)" coder 7 \
  'crashed'
agent_run_case 4 "status=CHANGES" "reviewer REQUEST CHANGES -> status=CHANGES, exit 4" reviewer 0 \
  '<verdict>REQUEST CHANGES</verdict>'
# A reviewer that only echoed its template has not judged anything; falling
# back to OK is the documented Phase 1 risk mitigation, not a silent pass.
agent_run_case 0 "status=OK" "reviewer echoing its own template -> status=OK" reviewer 0 \
  "$VERDICT_TEMPLATE_LINE"
# The agent-run path reads the log through the same parser, so the placement
# rule has to hold here too — otherwise a quoted tag still drives the exit code
# on the only path Phase 2 actually runs.
agent_run_case 0 "status=OK" "reviewer quoting the tag mid-log -> status=OK, not BLOCK" reviewer 0 \
  '개선안: 마지막 줄에 <verdict>BLOCK</verdict> 를 붙일 것

리뷰 계속'
# A run that crashed cannot be trusted to have finished reviewing, so the
# failure outranks the verdict sitting in the partial log: FAIL(1)/exit 3, not
# BLOCK/exit 5. Phase 2 must retry the run, not spend a loop budget on it.
agent_run_case 3 "status=FAIL(1)" "crashed run outranks the verdict in its log" reviewer 1 \
  '<verdict>BLOCK</verdict>'

# The agent-run path re-reads the log it just wrote to find the verdict. If
# that read fails the run must not be reported as a success — a verdict we
# could not read is not an approval. The stub CLI above owns the log for the
# whole run, so there is no seam to break it end-to-end; the guard is asserted
# on run_status() directly instead. Importing is safe: the script guards its
# entry point with `if __name__ == "__main__"`.
unreadable_log_case() {  # <description> <log-path>
  local desc="$1" path="$2" out msg err rc=0
  err=$(mktemp /tmp/hooktest-err-XXXXXX)
  out=$(python3 - "$REPO_ROOT/scripts/harness" "$path" 2>"$err" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import run_phase

status, code = run_phase.run_status(0, "reviewer", Path(sys.argv[2]))
print(status, code)
PY
  ) || rc=$?
  msg=$(cat "$err"); rm -f "$err"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'FAIL' \
     && printf '%s' "$out" | grep -q ' 3$' \
     && printf '%s' "$msg" | grep -q 'ERROR' \
     && ! printf '%s' "$msg" | grep -q 'Traceback'; then
    report 0 "run_phase.py" "$desc"
  else
    report 1 "run_phase.py" "$desc (rc=$rc out='$out' err='$msg')"
  fi
}

unreadable_log_case "agent log gone -> status FAIL, exit 3" "/nonexistent/phase.log"

if [ "$(id -u)" -eq 0 ]; then
  report 0 "run_phase.py" "unreadable agent log -> FAIL, exit 3 (skipped: running as root)"
else
  NOPERM_RUN_LOG=$(mktemp /tmp/hooktest-runlog-XXXXXX)
  printf '<verdict>APPROVE</verdict>\n' > "$NOPERM_RUN_LOG"
  chmod 000 "$NOPERM_RUN_LOG"
  unreadable_log_case "unreadable agent log -> FAIL, exit 3" "$NOPERM_RUN_LOG"
  chmod 600 "$NOPERM_RUN_LOG"; rm -f "$NOPERM_RUN_LOG"
fi

# Exit 2 must keep meaning "claude CLI missing" — the Phase 2 hook routes on
# it, and lowering the usage errors to 1 was only safe if 2 still says this.
CLI_ERR=$(mktemp /tmp/hooktest-err-XXXXXX)
RC=0
env PATH=/var/empty "$REAL_PY" "$RUN_PHASE" --subproject "$TMP_SUBPROJ" \
  --phase 999 --agent coder >/dev/null 2>"$CLI_ERR" || RC=$?
ERR=$(cat "$CLI_ERR"); rm -f "$CLI_ERR"
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'claude'; then
  report 0 "run_phase.py" "agent run without the claude CLI -> exit 2"
else
  report 1 "run_phase.py" "agent run without the claude CLI -> exit 2 (rc=$RC err='$ERR')"
fi

rm -rf "$TMP_SUBPROJ"
rm -f "$REPO_ROOT"/.claude/notes/phase-999-*.log

# The docstring is the only exit-code table a hook author reads before wiring
# up a `case $? in` — drift here silently mis-routes verdicts.
if grep -qE '^  4  ' "$RUN_PHASE" && grep -qE '^  5  ' "$RUN_PHASE"; then
  report 0 "run_phase.py" "docstring documents exit codes 4 and 5"
else
  report 1 "run_phase.py" "docstring documents exit codes 4 and 5"
fi

# ---------- record-verdict.sh ----------
# SubagentStop records, it never judges (D1). Its exit 2 would mean "prevent the
# subagent from stopping", i.e. keep the read-only reviewer running — which
# cannot fix anything. Judging lives in enforce-loop.sh on Stop.

STATE_REL=".claude/notes/loop-state.json"

new_proj() {  # -> path of a fresh temp project dir with .claude/notes/
  local d
  d=$(mktemp -d /tmp/hooktest-proj-XXXXXX)
  mkdir -p "$d/.claude/notes"
  printf '%s' "$d"
}

assistant_jsonl() {  # <path> <final-answer-text>: minimal subagent transcript
  # The real transcript is JSON Lines, and the reviewer's conclusion is the
  # text block of its last assistant record.
  {
    printf '{"type":"user","message":{"role":"user","content":"review the phase"}}\n'
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$2"
  } > "$1"
}

subagent_stop_json() {  # <agent_type> <transcript-path>
  printf '{"hook_event_name":"SubagentStop","agent_type":"%s","agent_transcript_path":"%s"}' \
    "$1" "$2"
}

record_run() {  # <proj> <payload> -> echoes the hook's exit code
  local proj="$1" payload="$2" rc=0
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOKS_DIR/$R" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

state_field() {  # <state-file> <key>
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' \
    "$1" "$2" 2>/dev/null
}

# A coder or a tester stopping says nothing about the review loop, so it must
# not create a counter out of nothing.
PROJ=$(new_proj)
assistant_jsonl "$PROJ/transcript.jsonl" '<verdict>BLOCK</verdict>'
RC=$(record_run "$PROJ" "$(subagent_stop_json coder "$PROJ/transcript.jsonl")")
if [ "$RC" -eq 0 ] && [ ! -f "$PROJ/$STATE_REL" ]; then
  report 0 "$R" "non-reviewer agent_type -> no loop-state.json, exit 0"
else
  report 1 "$R" "non-reviewer agent_type -> no loop-state.json, exit 0 (rc=$RC)"
fi
rm -rf "$PROJ"

# ...nor edit the one a previous reviewer left behind: every non-reviewer turn
# would otherwise nudge the counter the reviewer owns.
PROJ=$(new_proj)
printf '{"last_verdict":"BLOCK","attempt":2}\n' > "$PROJ/$STATE_REL"
assistant_jsonl "$PROJ/transcript.jsonl" '<verdict>APPROVE</verdict>'
RC=$(record_run "$PROJ" "$(subagent_stop_json tester "$PROJ/transcript.jsonl")")
if [ "$RC" -eq 0 ] && [ "$(state_field "$PROJ/$STATE_REL" attempt)" = "2" ] \
   && [ "$(state_field "$PROJ/$STATE_REL" last_verdict)" = "BLOCK" ]; then
  report 0 "$R" "non-reviewer agent_type -> existing loop-state.json untouched"
else
  report 1 "$R" "non-reviewer agent_type -> existing loop-state.json untouched (rc=$RC)"
fi
rm -rf "$PROJ"

record_state_case() {  # <desc> <agent> <verdict-text> <seed-state|-> <want-verdict> <want-attempt>
  local desc="$1" agent="$2" text="$3" seed="$4" want_v="$5" want_a="$6"
  local proj rc ok=0 got_v got_a
  proj=$(new_proj)
  [ "$seed" = "-" ] || printf '%s\n' "$seed" > "$proj/$STATE_REL"
  assistant_jsonl "$proj/transcript.jsonl" "$text"
  rc=$(record_run "$proj" "$(subagent_stop_json "$agent" "$proj/transcript.jsonl")")
  got_v=$(state_field "$proj/$STATE_REL" last_verdict)
  got_a=$(state_field "$proj/$STATE_REL" attempt)
  rm -rf "$proj"
  [ "$rc" -eq 0 ] && [ "$got_v" = "$want_v" ] && [ "$got_a" = "$want_a" ] || ok=1
  if [ "$ok" -eq 0 ]; then
    report 0 "$R" "$desc"
  else
    report 1 "$R" "$desc (rc=$rc, got $got_v/$got_a, want $want_v/$want_a)"
  fi
}

# A BLOCK spends one of the three attempts. The first one has no state file to
# read, so "increment" has to mean "start at 1", not "crash on a missing key".
record_state_case "reviewer BLOCK, no prior state -> last_verdict=BLOCK, attempt=1" \
  reviewer '<verdict>BLOCK</verdict>' - BLOCK 1

record_state_case "reviewer BLOCK again -> attempt increments 1 -> 2" \
  reviewer '<verdict>BLOCK</verdict>' '{"last_verdict":"BLOCK","attempt":1}' BLOCK 2

# A reviewer spawned as a teammate arrives under its teammate name — this repo's
# own .claude/notes/agent-activity.log carries reviewer-phase1 and
# reviewer-phase2. An exact match switches the whole loop off on that path, and
# nothing anywhere records that it was off.
record_state_case "reviewer spawned as reviewer-phase2 -> still records BLOCK" \
  reviewer-phase2 '<verdict>BLOCK</verdict>' - BLOCK 1
record_state_case "reviewer spawned as reviewer-phase1 -> still resets on APPROVE" \
  reviewer-phase1 '<verdict>APPROVE</verdict>' '{"last_verdict":"BLOCK","attempt":2}' APPROVE 0

# The prefix is a prefix, not a substring: an agent that merely has "reviewer"
# in its name does not own the loop counter.
PROJ=$(new_proj)
assistant_jsonl "$PROJ/transcript.jsonl" '<verdict>BLOCK</verdict>'
RC=$(record_run "$PROJ" "$(subagent_stop_json code-reviewer "$PROJ/transcript.jsonl")")
if [ "$RC" -eq 0 ] && [ ! -f "$PROJ/$STATE_REL" ]; then
  report 0 "$R" "code-reviewer is not the reviewer -> no loop-state.json, exit 0"
else
  report 1 "$R" "code-reviewer is not the reviewer -> no loop-state.json, exit 0 (rc=$RC)"
fi
rm -rf "$PROJ"

# The reviewer may quote a tag while deliberating; only its final answer counts.
# Reading thinking blocks would let a rehearsed APPROVE reset the budget.
#
# The thinking block is filed after the answer and its own last line is a bare
# tag, which is the only arrangement that tells the two rules apart: with the
# block filter removed the placement rule finds the rehearsed APPROVE and the
# budget resets. Thinking first would prove nothing — the text block's last line
# wins either way.
PROJ=$(new_proj)
{
  printf '{"type":"assistant","message":{"content":['
  printf '{"type":"text","text":"### 결론\\nBLOCK\\n\\n<verdict>BLOCK</verdict>"},'
  printf '{"type":"thinking","thinking":"<verdict>APPROVE</verdict> 로 끝낼걸 그랬나:\\n<verdict>APPROVE</verdict>"}'
  printf ']}}\n'
} > "$PROJ/transcript.jsonl"
RC=$(record_run "$PROJ" "$(subagent_stop_json reviewer "$PROJ/transcript.jsonl")")
if [ "$RC" -eq 0 ] && [ "$(state_field "$PROJ/$STATE_REL" last_verdict)" = "BLOCK" ]; then
  report 0 "$R" "thinking block quoting a verdict is ignored, text block wins"
else
  report 1 "$R" "thinking block quoting a verdict is ignored, text block wins (rc=$RC)"
fi
rm -rf "$PROJ"

# An approval ends the loop, so the budget has to be handed back intact — a
# counter that only ever climbs would starve the next phase of retries.
record_state_case "reviewer APPROVE -> last_verdict=APPROVE, attempt resets to 0" \
  reviewer '<verdict>APPROVE</verdict>' '{"last_verdict":"BLOCK","attempt":2}' APPROVE 0

# UNKNOWN is "the reviewer did not judge", not "the reviewer approved". It must
# neither spend an attempt nor hand the budget back (see Plans.md, Phase 1
# carry-over): a missing tag would otherwise reset the counter for free.
record_state_case "reviewer UNKNOWN -> recorded, attempt left as it was" \
  reviewer '리뷰 계속' '{"last_verdict":"BLOCK","attempt":2}' UNKNOWN 2

record_state_case "reviewer REQUEST CHANGES -> recorded as CHANGES, attempt increments" \
  reviewer '<verdict>REQUEST CHANGES</verdict>' '{"last_verdict":"BLOCK","attempt":1}' CHANGES 2

# Same headless-safe contract as announce-agent.sh: a payload this hook cannot
# read is not a reason to disturb the session, and not a reason to invent state.
survives_case() {  # <desc> <payload> [transcript-path-to-create]
  local desc="$1" payload="$2" proj rc
  proj=$(new_proj)
  rc=$(record_run "$proj" "$payload")
  if [ "$rc" -eq 0 ] && [ ! -f "$proj/$STATE_REL" ]; then
    report 0 "$R" "$desc"
  else
    report 1 "$R" "$desc (rc=$rc)"
  fi
  rm -rf "$proj"
}

survives_case "garbage stdin -> exit 0, no state written" 'not json at all'
survives_case "empty payload -> exit 0, no state written" '{}'
# A reviewer whose transcript cannot be read does write one thing — the failure
# mark, so the next Stop can say so. That pair of cases lives further down, with
# the rest of the marking behaviour ("mark_only_case").

# `transcript_path` is the MAIN session's transcript, not the subagent's, and
# its last assistant text is whatever the main session said — a verdict quoted
# back to the user reads exactly like one the reviewer made. There is no
# guessing available here: no subagent transcript, no record.
PROJ=$(new_proj)
assistant_jsonl "$PROJ/main-session.jsonl" '메인 세션이 인용한 판정입니다: <verdict>BLOCK</verdict>'
ERR=$(printf '{"hook_event_name":"SubagentStop","agent_type":"reviewer","transcript_path":"%s"}' \
  "$PROJ/main-session.jsonl" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOKS_DIR/$R" 2>&1 >/dev/null)
RC=$?
# No verdict of any kind may appear here. The failure mark is the one write this
# path is allowed, and the assertion is that it arrives alone.
GOT_V=$(state_field "$PROJ/$STATE_REL" last_verdict)
if [ "$RC" -eq 0 ] && [ -z "$GOT_V" ] && printf '%s' "$ERR" | grep -qi 'WARNING'; then
  report 0 "$R" "no agent_transcript_path -> the main transcript is not read, warning, exit 0"
else
  report 1 "$R" "no agent_transcript_path -> the main transcript is not read, warning, exit 0 (rc=$RC verdict='$GOT_V' err='$ERR')"
fi
rm -rf "$PROJ"

# A transcript whose lines are not JSON is a truncated write, not a verdict.
PROJ=$(new_proj)
printf 'half a line without a close\n' > "$PROJ/transcript.jsonl"
RC=$(record_run "$PROJ" "$(subagent_stop_json reviewer "$PROJ/transcript.jsonl")")
if [ "$RC" -eq 0 ] && [ "$(state_field "$PROJ/$STATE_REL" last_verdict)" = "UNKNOWN" ]; then
  report 0 "$R" "unparseable transcript lines -> UNKNOWN, exit 0"
else
  report 1 "$R" "unparseable transcript lines -> UNKNOWN, exit 0 (rc=$RC)"
fi
rm -rf "$PROJ"

# No JSON reader at all: the hook goes quiet rather than half-recording, but it
# says so — a loop budget that silently stopped being counted is worse than one
# that is loudly not counted.
PROJ=$(new_proj)
assistant_jsonl "$PROJ/transcript.jsonl" '<verdict>BLOCK</verdict>'
ERR=$(printf '%s' "$(subagent_stop_json reviewer "$PROJ/transcript.jsonl")" \
  | env PATH=/var/empty CLAUDE_PROJECT_DIR="$PROJ" /bin/bash "$HOOKS_DIR/$R" 2>&1 >/dev/null)
RC=$?
# The warning has to be the only thing on stderr: a shell error alongside it
# reads as a broken hook and trains the reader to ignore the channel.
if [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -qi 'WARNING' \
   && ! printf '%s' "$ERR" | grep -q 'command not found' \
   && [ ! -f "$PROJ/$STATE_REL" ]; then
  report 0 "$R" "no jq and no python3 -> warning on stderr, exit 0"
else
  report 1 "$R" "no jq and no python3 -> warning on stderr, exit 0 (rc=$RC err='$ERR')"
fi
rm -rf "$PROJ"

# The one exit code this hook must never produce (D1). On SubagentStop, exit 2
# means "prevent the subagent from stopping" — the read-only reviewer would be
# told to keep going with nothing it is allowed to change.
PROJ=$(new_proj)
assistant_jsonl "$PROJ/block.jsonl" '<verdict>BLOCK</verdict>'
assistant_jsonl "$PROJ/approve.jsonl" '<verdict>APPROVE</verdict>'
printf 'garbage\n' > "$PROJ/garbage.jsonl"
printf '\xff\xfe\x00 truncated {"type":"assistant"\n' > "$PROJ/binary.jsonl"
printf '{"last_verdict":' > "$PROJ/$STATE_REL"  # a half-written counter, on purpose

SAW_TWO=""
for PAYLOAD in \
  'not json at all' \
  '{}' \
  '[]' \
  'null' \
  '' \
  '{"hook_event_name":"SubagentStop","agent_type":null}' \
  "$(subagent_stop_json coder "$PROJ/block.jsonl")" \
  "$(subagent_stop_json reviewer "$PROJ/block.jsonl")" \
  "$(subagent_stop_json reviewer "$PROJ/approve.jsonl")" \
  "$(subagent_stop_json reviewer "$PROJ/garbage.jsonl")" \
  "$(subagent_stop_json reviewer "$PROJ/binary.jsonl")" \
  "$(subagent_stop_json reviewer "$PROJ")" \
  "$(subagent_stop_json reviewer /nonexistent/x.jsonl)" \
  "$(subagent_stop_json reviewer '')"; do
  RC=$(record_run "$PROJ" "$PAYLOAD")
  [ "$RC" -eq 2 ] && SAW_TWO="$SAW_TWO|$PAYLOAD"
done
RC=0
printf '%s' "$(subagent_stop_json reviewer "$PROJ/block.jsonl")" \
  | env PATH=/var/empty CLAUDE_PROJECT_DIR="$PROJ" /bin/bash "$HOOKS_DIR/$R" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 2 ] && SAW_TWO="$SAW_TWO|no-jq-no-python3"
if [ -z "$SAW_TWO" ]; then
  report 0 "$R" "no input produces exit 2 (D1: never stop the subagent from stopping)"
else
  report 1 "$R" "no input produces exit 2 (got 2 for: $SAW_TWO)"
fi
rm -rf "$PROJ"

# ---------- enforce-loop.sh ----------
# Stop is where the loop is enforced (D1): its exit 2 means "do not stop,
# continue the conversation", which hands control back to the main session so
# it can re-dispatch the coder. record-verdict.sh only writes the state.

stop_json() {  # [stop_hook_active]
  printf '{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":%s}' "${1:-false}"
}

enforce_case() {  # <expected-exit> <desc> <state|-> <payload> <want-stderr|-> <want-stdout|-> [PATH]
  local expected="$1" desc="$2" state="$3" payload="$4" want_err="$5" want_out="$6"
  local path="${7:-$PATH}"
  local proj out msg err rc=0 ok=0
  proj=$(new_proj)
  [ "$state" = "-" ] || printf '%s\n' "$state" > "$proj/$STATE_REL"
  err=$(mktemp /tmp/hooktest-err-XXXXXX)
  out=$(printf '%s' "$payload" \
    | env PATH="$path" CLAUDE_PROJECT_DIR="$proj" /bin/bash "$HOOKS_DIR/$E" 2>"$err") || rc=$?
  msg=$(cat "$err"); rm -f "$err"; rm -rf "$proj"
  [ "$rc" -eq "$expected" ] || ok=1
  [ "$want_err" = "-" ] || printf '%s' "$msg" | grep -qF "$want_err" || ok=1
  [ "$want_out" = "-" ] || printf '%s' "$out" | grep -qF "$want_out" || ok=1
  if [ "$ok" -eq 0 ]; then
    report 0 "$E" "$desc"
  else
    report 1 "$E" "$desc (rc=$rc out='$out' err='$msg')"
  fi
}

# Stop fires at the end of EVERY main turn, including plain conversation. If
# this guard ever leaks, ordinary chat gets trapped in a hook it never asked
# for — which is why it is the first thing the script checks.
enforce_case 0 "no loop-state.json -> exit 0 (an ordinary turn is not a loop)" \
  - "$(stop_json)" - -

# A BLOCK with budget left is the case the whole plan exists for: the turn must
# not end, and the model has to be told what to do with the turn it just got
# back. stderr is the only channel Stop's exit 2 gives us for that.
enforce_case 2 "BLOCK at attempt 1 -> exit 2, stderr counts the attempt (1/3)" \
  '{"last_verdict":"BLOCK","attempt":1}' "$(stop_json)" 'attempt 1/3' -

enforce_case 2 "BLOCK at attempt 1 -> stderr names the verdict being acted on" \
  '{"last_verdict":"BLOCK","attempt":1}' "$(stop_json)" 'BLOCK' -

enforce_case 2 "BLOCK at attempt 1 -> stderr says to re-dispatch the coder" \
  '{"last_verdict":"BLOCK","attempt":1}' "$(stop_json)" 'coder' -

# The reviewer's own wording, as it appears in the <verdict> tag. record-verdict
# stores the normalized "CHANGES", but a state file written by hand or by an
# older build carries the long form, and both mean "not done".
enforce_case 2 "REQUEST CHANGES at attempt 2 -> exit 2, stderr counts 2/3" \
  '{"last_verdict":"REQUEST CHANGES","attempt":2}' "$(stop_json)" 'attempt 2/3' -

enforce_case 2 "CHANGES (normalized) at attempt 2 -> exit 2, stderr counts 2/3" \
  '{"last_verdict":"CHANGES","attempt":2}' "$(stop_json)" 'attempt 2/3' -

# The two verdicts that end the loop. APPROVE is the loop succeeding; UNKNOWN is
# the reviewer never having judged, which Plans.md Phase 1 deliberately keeps
# open so a missing tag falls back to the pre-hook behaviour instead of
# stalling the session.
enforce_case 0 "APPROVE -> exit 0" '{"last_verdict":"APPROVE","attempt":0}' "$(stop_json)" - -
enforce_case 0 "UNKNOWN -> exit 0 (no judgement is not a failed review)" \
  '{"last_verdict":"UNKNOWN","attempt":2}' "$(stop_json)" - -

# Budget spent. The turn is allowed to end — three more machine attempts will
# not find what three already missed — but it must not read as a clean finish,
# so the exhaustion says out loud that a human has to take it from here.
enforce_case 0 "BLOCK at attempt 3 -> exit 0, the budget is spent" \
  '{"last_verdict":"BLOCK","attempt":3}' "$(stop_json)" - '3/3'

enforce_case 0 "BLOCK at attempt 3 -> stdout asks for a human, not a success" \
  '{"last_verdict":"BLOCK","attempt":3}' "$(stop_json)" - '사람 개입'

enforce_case 0 "BLOCK at attempt 3 -> stdout still names the unresolved verdict" \
  '{"last_verdict":"BLOCK","attempt":3}' "$(stop_json)" - 'BLOCK'

# Past the boundary. A counter that overshot (a stale file, a hand edit, two
# reviewers in one phase) must still let the turn end: the comparison is a
# threshold, not an equality test.
enforce_case 0 "BLOCK at attempt 4 -> exit 0, still past the budget" \
  '{"last_verdict":"BLOCK","attempt":4}' "$(stop_json)" - '사람 개입'

# stop_hook_active means this turn only exists because a Stop hook blocked the
# previous one. Blocking again would re-block our own continuation forever;
# Claude Code caps that at 8, but the budget of 3 is meant to bite first, and
# this guard is what makes it possible to bite at all.
enforce_case 0 "stop_hook_active=true -> exit 0, no second block on our own continuation" \
  '{"last_verdict":"BLOCK","attempt":1}' "$(stop_json true)" - -

# Anything this hook cannot read is a reason to let go of the turn, never to
# hold it: a session held by a hook that no longer knows what it is enforcing
# cannot be talked out of it. Loudly, though — a budget that quietly stopped
# being counted is the failure this whole phase exists to prevent.
enforce_case 0 "garbage Stop payload -> exit 0 + warning (never trap the session)" \
  '{"last_verdict":"BLOCK","attempt":1}' 'not json at all' 'WARNING' -

enforce_case 0 "empty Stop payload -> exit 0 + warning" \
  '{"last_verdict":"BLOCK","attempt":1}' '' 'WARNING' -

enforce_case 0 "truncated loop-state.json -> exit 0 + warning" \
  '{"last_verdict":' "$(stop_json)" 'WARNING' -

enforce_case 0 "loop-state.json holding a JSON array -> exit 0 + warning" \
  '[]' "$(stop_json)" 'WARNING' -

# Valid JSON, unusable counter. Without a check this reaches `[ "$a" -ge 3 ]`,
# where bash's own "integer expression expected" makes the test false and the
# turn gets blocked on a number nobody can count.
enforce_case 0 "non-numeric attempt -> exit 0 + warning" \
  '{"last_verdict":"BLOCK","attempt":"two"}' "$(stop_json)" 'WARNING' -

# Whether a host has jq decides which of the two readers runs, and nothing
# else may follow from it. The PATH here holds exactly what the hook shells out
# to — cat and python3 — so "no jq" is real absence, not a stub.
NOJQ_BIN=$(mktemp -d /tmp/hooktest-nojq-XXXXXX)
ln -s "$REAL_PY" "$NOJQ_BIN/python3"
ln -s "$(command -v cat)" "$NOJQ_BIN/cat"

enforce_case 0 "python3 fallback: APPROVE -> exit 0" \
  '{"last_verdict":"APPROVE","attempt":0}' "$(stop_json)" - - "$NOJQ_BIN"
enforce_case 2 "python3 fallback: BLOCK at attempt 1 -> exit 2, counts 1/3" \
  '{"last_verdict":"BLOCK","attempt":1}' "$(stop_json)" 'attempt 1/3' - "$NOJQ_BIN"
enforce_case 0 "python3 fallback: BLOCK at attempt 3 -> exit 0, asks for a human" \
  '{"last_verdict":"BLOCK","attempt":3}' "$(stop_json)" - '사람 개입' "$NOJQ_BIN"
enforce_case 0 "python3 fallback: stop_hook_active=true -> exit 0" \
  '{"last_verdict":"BLOCK","attempt":1}' "$(stop_json true)" - - "$NOJQ_BIN"
enforce_case 0 "python3 fallback: truncated loop-state.json -> exit 0 + warning" \
  '{"last_verdict":' "$(stop_json)" 'WARNING' - "$NOJQ_BIN"
enforce_case 0 "python3 fallback: loop-state.json holding a JSON array -> exit 0 + warning" \
  '[]' "$(stop_json)" 'WARNING' - "$NOJQ_BIN"
enforce_case 0 "python3 fallback: garbage Stop payload -> exit 0 + warning" \
  '{"last_verdict":"BLOCK","attempt":1}' 'not json at all' 'WARNING' - "$NOJQ_BIN"
enforce_case 0 "python3 fallback: non-numeric attempt -> exit 0 + warning" \
  '{"last_verdict":"BLOCK","attempt":"two"}' "$(stop_json)" 'WARNING' - "$NOJQ_BIN"

rm -rf "$NOJQ_BIN"

# Neither reader present: the hook says so and lets the turn end, exactly like
# the other guards in this repo. It never holds a session it cannot judge.
enforce_case 0 "no jq and no python3 -> exit 0 + warning" \
  '{"last_verdict":"BLOCK","attempt":1}' "$(stop_json)" 'WARNING' - /var/empty

# ---------- enforce-loop.sh : one verdict buys one reaction ----------
# Nothing in the repo deletes loop-state.json, and attempt only grows when a
# reviewer runs — so a loop the user walked away from (Esc, a change of subject,
# a closed session) leaves a BLOCK on disk that never ages out. Without a
# consume-once mark, every later turn of every later session ends in exit 2
# telling the model to re-dispatch a coder for a phase nobody is working on.
#
# A re-dispatch is one reaction to a verdict; the hand-over-to-a-human banner an
# exhausted budget prints is the other. Both are covered here, because a state
# with attempt at 3 never reaches the exit 2 path at all.

later_turn() {  # <proj> <session-id> -> exit code of one Stop with no reviewer in between
  local rc=0
  printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$HOOKS_DIR/$E" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

PROJ=$(new_proj)
printf '{"last_verdict":"BLOCK","attempt":1}\n' > "$PROJ/$STATE_REL"
RC1=$(later_turn "$PROJ" s1)
RC2=$(later_turn "$PROJ" a-later-session)
RC3=$(later_turn "$PROJ" a-different-session-days-later)
GOT_A=$(state_field "$PROJ/$STATE_REL" attempt)
rm -rf "$PROJ"
if [ "$RC1" -eq 2 ] && [ "$RC2" -eq 0 ] && [ "$RC3" -eq 0 ] && [ "$GOT_A" = "1" ]; then
  report 0 "$E" "an abandoned BLOCK blocks once, then lets later turns end"
else
  report 1 "$E" "an abandoned BLOCK blocks once, then lets later turns end (rc=$RC1/$RC2/$RC3 attempt=$GOT_A)"
fi

# An exhausted budget exits 0, so it holds no turn — but it announces the
# hand-over on stdout, and an abandoned one announces it on every message the
# user sends, forever. Milder than the block above, same root cause: the
# escalation is a reaction, and the verdict already paid for one.
abandoned_turn() {  # <proj> <session-id> -> stdout of one Stop, no reviewer in between
  printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$HOOKS_DIR/$E" 2>/dev/null
}

PROJ=$(new_proj)
printf '{"last_verdict":"BLOCK","attempt":3}\n' > "$PROJ/$STATE_REL"
OUT1=$(abandoned_turn "$PROJ" s1); RC1=$?
OUT2=$(abandoned_turn "$PROJ" a-later-session); RC2=$?
OUT3=$(abandoned_turn "$PROJ" a-different-session-days-later); RC3=$?
GOT_A=$(state_field "$PROJ/$STATE_REL" attempt)
rm -rf "$PROJ"
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$RC3" -eq 0 ] && [ "$GOT_A" = "3" ] \
   && printf '%s' "$OUT1" | grep -qF '3/3' && printf '%s' "$OUT1" | grep -qF '사람 개입' \
   && [ -z "$OUT2" ] && [ -z "$OUT3" ]; then
  report 0 "$E" "an abandoned spent budget asks for a human once, then goes quiet"
else
  report 1 "$E" "an abandoned spent budget asks for a human once, then goes quiet (rc=$RC1/$RC2/$RC3 attempt=$GOT_A out1='$OUT1' out2='$OUT2' out3='$OUT3')"
fi

# The live loop is what must not change: the reviewer records a fresh verdict on
# every cycle, and a fresh verdict is unspent. If consuming one leaked into the
# next cycle, enforcement would switch itself off after the first attempt.
PROJ=$(new_proj)
assistant_jsonl "$PROJ/block.jsonl" '<verdict>BLOCK</verdict>'
BLOCKED_TWICE=""
record_run "$PROJ" "$(subagent_stop_json reviewer "$PROJ/block.jsonl")" >/dev/null
[ "$(later_turn "$PROJ" s1)" -eq 2 ] || BLOCKED_TWICE="first cycle did not block"
record_run "$PROJ" "$(subagent_stop_json reviewer "$PROJ/block.jsonl")" >/dev/null
RC=0
OUT=$(printf '%s' "$(stop_json)" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOKS_DIR/$E" 2>&1) || RC=$?
rm -rf "$PROJ"
if [ -z "$BLOCKED_TWICE" ] && [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'attempt 2/3'; then
  report 0 "loop" "a new reviewer verdict re-arms enforcement (a live loop is unaffected)"
else
  report 1 "loop" "a new reviewer verdict re-arms enforcement ($BLOCKED_TWICE rc=$RC out='$OUT')"
fi

# A verdict that lands between this hook's read and its mark has not been reacted
# to by anyone. The two hooks are separate processes on separate events and this
# harness runs reviewers as background teammates, so a SubagentStop really can
# land inside a Stop — but a test that waits for it would be timing, not a test.
# The seam below is that interleaving made deterministic: a python3 that writes a
# newer verdict into the state file and only then runs the real one, so the mark
# always sees a state this hook never read. Stamping that newer verdict spent
# would leave a BLOCK nobody answered, and the next Stop would let the turn end
# — enforcement off in a live loop, the failure this phase exists to prevent.
PROJ=$(new_proj)
printf '{"last_verdict":"BLOCK","attempt":1,"enforced":false}\n' > "$PROJ/$STATE_REL"
RACE_BIN=$(mktemp -d /tmp/hooktest-race-XXXXXX)
cat > "$RACE_BIN/python3" <<EOF
#!/bin/bash
# The hook passes its edit mode as the first argument after the \`-\`, so
# "mark-enforced" is exactly "the enforced mark is about to be written" — and
# not any of the hook's other python3 calls, which read the file or clear a
# different key. enforce-loop.sh carries a comment saying this seam depends on
# that word.
[ "\${2-}" = "mark-enforced" ] && printf '{"last_verdict":"BLOCK","attempt":2,"enforced":false}\n' > "$PROJ/$STATE_REL"
exec "$REAL_PY" "\$@"
EOF
chmod +x "$RACE_BIN/python3"
RC=0
ERR=$(printf '%s' "$(stop_json)" \
  | env PATH="$RACE_BIN:$PATH" CLAUDE_PROJECT_DIR="$PROJ" /bin/bash "$HOOKS_DIR/$E" 2>&1 >/dev/null) || RC=$?
GOT_A=$(state_field "$PROJ/$STATE_REL" attempt)
GOT_E=$(state_field "$PROJ/$STATE_REL" enforced)
rm -rf "$PROJ" "$RACE_BIN"
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF 'attempt 1/3' \
   && [ "$GOT_A" = "2" ] && [ "$GOT_E" != "True" ]; then
  report 0 "$E" "a verdict that landed after the read is left unspent"
else
  report 1 "$E" "a verdict that landed after the read is left unspent (rc=$RC attempt=$GOT_A enforced=$GOT_E err='$ERR')"
fi

# ---------- settings.json wiring ----------
# A hook that is written but not registered enforces nothing, and the failure
# is invisible: the session just carries on as it did before.
SETTINGS="$REPO_ROOT/.claude/settings.json"

event_hooks() {  # <event> -> one command per line
  python3 -c '
import json, sys

with open(sys.argv[1]) as f:
    settings = json.load(f)
for group in settings.get("hooks", {}).get(sys.argv[2], []):
    for hook in group.get("hooks", []):
        print(hook.get("command", ""))
' "$SETTINGS" "$1" 2>/dev/null
}

registered_case() {  # <desc> <event> <hook-file>
  if event_hooks "$2" | grep -qF "$3"; then
    report 0 "settings.json" "$1"
  else
    report 1 "settings.json" "$1"
  fi
}

registered_case "SubagentStop still runs announce-agent.sh" SubagentStop "$A"
registered_case "SubagentStop also runs record-verdict.sh" SubagentStop "$R"
registered_case "SubagentStart still runs announce-agent.sh" SubagentStart "$A"
registered_case "Stop runs enforce-loop.sh" Stop "$E"

# Same-event hooks run in parallel in a non-deterministic order (D2), so the
# two SubagentStop entries have to be independent — which is only worth
# checking because there are now two of them.
if [ "$(event_hooks SubagentStop | grep -c .)" -eq 2 ]; then
  report 0 "settings.json" "SubagentStop registers exactly the two known hooks"
else
  report 1 "settings.json" "SubagentStop registers exactly the two known hooks"
fi

# A typo in a command path is silent: Claude Code just runs nothing.
MISSING_HOOKS=""
for EV in PreToolUse PostToolUse SubagentStart SubagentStop Stop; do
  while IFS= read -r CMD; do
    [ -n "$CMD" ] || continue
    CMD_FILE="${CMD##*/}"
    CMD_FILE="${CMD_FILE%\"}"
    [ -f "$HOOKS_DIR/$CMD_FILE" ] || MISSING_HOOKS="$MISSING_HOOKS $CMD"
  done <<< "$(event_hooks "$EV")"
done
if [ -z "$MISSING_HOOKS" ]; then
  report 0 "settings.json" "every registered command points at a hook file that exists"
else
  report 1 "settings.json" "every registered command points at a hook file that exists ($MISSING_HOOKS)"
fi

# D2: announce-agent.sh keeps its cosmetic-only contract. It shares an event
# with record-verdict.sh and must not grow a stake in the loop state.
if grep -qF 'Cosmetic only: always exit 0, never block' "$HOOKS_DIR/$A" \
   && ! grep -qF 'loop-state' "$HOOKS_DIR/$A"; then
  report 0 "$A" "still cosmetic only, with no stake in the loop state"
else
  report 1 "$A" "still cosmetic only, with no stake in the loop state"
fi

# ---------- record-verdict.sh + enforce-loop.sh : the budget end to end ----------
# The two hooks only mean something together: one counts, the other stops. Run
# them in the order a real session would and walk the budget to its end.
PROJ=$(new_proj)
# \n stays a JSON escape here: the transcript is one record per physical line.
assistant_jsonl "$PROJ/transcript.jsonl" '### 결론\nBLOCK — 하드코딩된 토큰\n\n<verdict>BLOCK</verdict>'
BLOCK_PAYLOAD=$(subagent_stop_json reviewer "$PROJ/transcript.jsonl")

loop_turn() {  # -> "<exit-code> <stdout+stderr>" of one reviewer-then-Stop cycle
  local out rc=0
  record_run "$PROJ" "$BLOCK_PAYLOAD" >/dev/null
  out=$(printf '%s' "$(stop_json)" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOKS_DIR/$E" 2>&1) || rc=$?
  printf '%s %s' "$rc" "$out"
}

TURN1=$(loop_turn)
TURN2=$(loop_turn)
TURN3=$(loop_turn)
case "$TURN1 :: $TURN2 :: $TURN3" in
  "2 "*"attempt 1/3"*"2 "*"attempt 2/3"*"사람 개입"*)
    report 0 "loop" "three BLOCKs: continue, continue, then hand over to a human" ;;
  *)
    report 1 "loop" "three BLOCKs: continue, continue, then hand over to a human ($TURN1 :: $TURN2 :: $TURN3)" ;;
esac

# An APPROVE mid-loop hands the budget back, so the next phase starts from 3
# again rather than inheriting a spent counter.
assistant_jsonl "$PROJ/transcript.jsonl" '<verdict>APPROVE</verdict>'
RC=$(record_run "$PROJ" "$(subagent_stop_json reviewer "$PROJ/transcript.jsonl")")
APPROVED=$(printf '%s' "$(stop_json)" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOKS_DIR/$E" 2>&1; printf ' rc=%s' "$?")
if [ "$RC" -eq 0 ] && [ "$(state_field "$PROJ/$STATE_REL" attempt)" = "0" ] \
   && [ "$APPROVED" = " rc=0" ]; then
  report 0 "loop" "an APPROVE after a spent budget ends the loop and resets it"
else
  report 1 "loop" "an APPROVE after a spent budget ends the loop and resets it (rc=$RC out='$APPROVED')"
fi
rm -rf "$PROJ"

# ---------- record-verdict.sh : what counts as the reviewer's answer ----------
# The transcript is JSON Lines, and an assistant record carries `message.content`
# as a list of typed blocks. Only `text` blocks are the reviewer speaking;
# `thinking` is it talking to itself. Reading thinking would let a rehearsed
# verdict — "if this were BLOCK I'd write ..." — overwrite the real one, in
# either direction, which is why both directions are pinned.

record_jsonl_case() {  # <desc> <seed|-> <want-verdict> <want-attempt> <jsonl-body|-->
  local desc="$1" seed="$2" want_v="$3" want_a="$4" body="$5"
  local proj rc got_v got_a ok=0
  proj=$(new_proj)
  [ "$seed" = "-" ] || printf '%s\n' "$seed" > "$proj/$STATE_REL"
  # `--` writes a genuinely empty file; printf would leave a newline behind.
  if [ "$body" = "--" ]; then : > "$proj/transcript.jsonl"
  else printf '%s\n' "$body" > "$proj/transcript.jsonl"
  fi
  rc=$(record_run "$proj" "$(subagent_stop_json reviewer "$proj/transcript.jsonl")")
  got_v=$(state_field "$proj/$STATE_REL" last_verdict)
  got_a=$(state_field "$proj/$STATE_REL" attempt)
  rm -rf "$proj"
  [ "$rc" -eq 0 ] && [ "$got_v" = "$want_v" ] && [ "$got_a" = "$want_a" ] || ok=1
  if [ "$ok" -eq 0 ]; then
    report 0 "$R" "$desc"
  else
    report 1 "$R" "$desc (rc=$rc, got $got_v/$got_a, want $want_v/$want_a)"
  fi
}

# The mirror of the existing thinking-block case: deliberating about BLOCK and
# then approving must record the approval, or a reviewer that thinks out loud
# could never clear the budget it just decided to clear.
record_jsonl_case "thinking weighs BLOCK, final text APPROVEs -> APPROVE, attempt resets" \
  '{"last_verdict":"BLOCK","attempt":2}' APPROVE 0 \
  '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"if this were BLOCK I would write <verdict>BLOCK</verdict>"},{"type":"text","text":"### 결론\nAPPROVE — 이슈 없음\n\n<verdict>APPROVE</verdict>"}]}}'

# Phase 1 decided a tag counts only on the last non-empty line, and this hook is
# required to reuse run_phase.py rather than re-derive that rule in bash. The
# round trip is what proves the delegation: a final answer that quotes a tag
# mid-message and then stops judging must land as UNKNOWN in the state file, not
# as the quoted APPROVE. Getting this wrong resets the retry budget for free.
record_jsonl_case "final text quotes a tag but never judges -> UNKNOWN, attempt untouched" \
  '{"last_verdict":"BLOCK","attempt":2}' UNKNOWN 2 \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"개선안: 마지막 줄에 <verdict>APPROVE</verdict> 를 붙일 것\n\n리뷰 계속"}]}}'

# --parse-verdict answers APPROVE and UNKNOWN with the same exit 0, so the hook
# has to read stdout to tell them apart. These two cases differ in nothing but
# the verdict word, and only one of them may hand the budget back.
record_jsonl_case "APPROVE (exit 0) hands the budget back" \
  '{"last_verdict":"BLOCK","attempt":2}' APPROVE 0 \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"<verdict>APPROVE</verdict>"}]}}'
record_jsonl_case "UNKNOWN (also exit 0) does not hand the budget back" \
  '{"last_verdict":"BLOCK","attempt":2}' UNKNOWN 2 \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"리뷰 계속"}]}}'

# A transcript with nothing to say is not an approval. Each of these is a real
# shape: a run killed before it answered, a run that only used tools, and a run
# whose last record was pure deliberation.
record_jsonl_case "empty transcript file -> UNKNOWN, attempt untouched" \
  '{"last_verdict":"BLOCK","attempt":2}' UNKNOWN 2 --
record_jsonl_case "transcript with no assistant records -> UNKNOWN" \
  '{"last_verdict":"BLOCK","attempt":2}' UNKNOWN 2 \
  '{"type":"user","message":{"role":"user","content":"review the phase"}}'
# The tag here sits on the thinking block's own last line, which is the only
# shape that tells the two rules apart: with the block filter removed the
# placement rule would find it and record BLOCK. A thinking-first transcript
# cannot detect that at all — the text block's last line wins either way — so
# the two cases below are the ones that actually hold the filter in place.
record_jsonl_case "last record holds only thinking, no text -> UNKNOWN" \
  '{"last_verdict":"BLOCK","attempt":2}' UNKNOWN 2 \
  '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"이렇게 끝낼까:\n<verdict>BLOCK</verdict>"}]}}'

# Same trick, but with the answer present and the deliberation filed after it.
# Block order is not a contract, so the verdict has to come from the block type,
# never from whichever block happens to be last.
record_jsonl_case "thinking filed after the answer -> the text block still decides" \
  - APPROVE 0 \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"### 결론\nAPPROVE — 이슈 없음\n\n<verdict>APPROVE</verdict>"},{"type":"thinking","thinking":"다시 보니 이쪽이었나:\n<verdict>BLOCK</verdict>"}]}}'

# Older transcripts carry `content` as a bare string instead of a block list.
record_jsonl_case "content as a plain string -> still parsed" \
  - BLOCK 1 '{"type":"assistant","message":{"content":"<verdict>BLOCK</verdict>"}}'

# The answer is the LAST assistant record that said something, so a tool call
# after the verdict must not erase it, and an earlier verdict must not win.
record_jsonl_case "two assistant records -> the last one wins" \
  - BLOCK 1 \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"<verdict>APPROVE</verdict>"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"<verdict>BLOCK</verdict>"}]}}'
record_jsonl_case "a tool_use-only record does not shadow the answer" \
  - BLOCK 1 \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"<verdict>BLOCK</verdict>"}]}}'

record_jsonl_case "unicode / emoji / RTL in the reviewer's answer" \
  - BLOCK 1 \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"BLOCK — 하드코딩된 토큰 🚨 مرحبا\n\n<verdict>BLOCK</verdict>"}]}}'

# A counter this hook cannot read is not a reason to refuse to record. Restarting
# at 1 loses at most one attempt; refusing would lose the budget entirely.
record_jsonl_case "seed attempt is not a number -> restart the count at 1" \
  '{"last_verdict":"BLOCK","attempt":"two"}' BLOCK 1 \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"<verdict>BLOCK</verdict>"}]}}'
record_jsonl_case "seed state is a JSON array -> restart the count at 1" \
  '[]' BLOCK 1 \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"<verdict>BLOCK</verdict>"}]}}'

# The placement rule has exactly one owner. If it were re-derived in bash the
# two copies would drift, and the round-trip cases above would keep passing
# right up until the day they disagreed.
if grep -qF -- '--parse-verdict' "$HOOKS_DIR/$R"; then
  report 0 "$R" "the verdict is parsed by run_phase.py, not re-derived in bash"
else
  report 1 "$R" "the verdict is parsed by run_phase.py, not re-derived in bash"
fi

# ---------- record-verdict.sh : temp file hygiene ----------
# The hook stages the reviewer's answer in a temp file to feed --parse-verdict.
# A hook fires on every subagent stop, so one leaked file per review is a slow
# leak in the user's TMPDIR — and the leak would be worst on the error paths,
# which are the ones nobody runs by hand.
HYGIENE_TMP=$(mktemp -d /tmp/hooktest-tmpdir-XXXXXX)
PROJ=$(new_proj)
assistant_jsonl "$PROJ/transcript.jsonl" '<verdict>BLOCK</verdict>'
printf '<verdict>BLOCK</verdict>\n' > "$PROJ/noperm.jsonl"
[ "$(id -u)" -eq 0 ] || chmod 000 "$PROJ/noperm.jsonl"
for TPATH in "$PROJ/transcript.jsonl" /nonexistent/x.jsonl "$PROJ" "" "$PROJ/noperm.jsonl"; do
  printf '{"agent_type":"reviewer","agent_transcript_path":"%s"}' "$TPATH" \
    | TMPDIR="$HYGIENE_TMP" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOKS_DIR/$R" >/dev/null 2>&1
done
LEFTOVERS=$(ls -A "$HYGIENE_TMP")
[ "$(id -u)" -eq 0 ] || chmod 600 "$PROJ/noperm.jsonl"
rm -rf "$HYGIENE_TMP" "$PROJ"
if [ -z "$LEFTOVERS" ]; then
  report 0 "$R" "no temp files left behind, on the good path or any error path"
else
  report 1 "$R" "no temp files left behind, on the good path or any error path ($LEFTOVERS)"
fi

# ---------- record-verdict.sh : a parser that did not run is not a verdict ----------
# Everything the hook writes comes from run_phase.py. If the parser cannot run
# at all — a wrong path to it, a crash inside it — the hook knows nothing about
# the review, and "nothing" must stay off the disk: writing an empty verdict
# would spend one of the three attempts *and* leave enforce-loop.sh a value it
# reads as "no loop", releasing the turn. Wrong in both directions at once.

orphan_hook() {  # [stub-run_phase.py body] -> dir holding a copy of the hook
  # A copy of the hook whose sibling scripts/harness/run_phase.py is missing
  # (or replaced by a stub): what a crashing or unreachable parser looks like
  # from inside the hook, without touching the real one.
  local root
  root=$(mktemp -d /tmp/hooktest-orphan-XXXXXX)
  mkdir -p "$root/.claude/hooks"
  cp "$HOOKS_DIR/$R" "$root/.claude/hooks/$R"
  if [ "$#" -gt 0 ]; then
    mkdir -p "$root/scripts/harness"
    printf '%s\n' "$1" > "$root/scripts/harness/run_phase.py"
  fi
  printf '%s' "$root"
}

# ...but "nothing" is not the same as silence. consume-once means the previous
# verdict has already been spent, so a hook that cannot record leaves a turn that
# simply ends, with one line on a stderr channel the user sees only in transcript
# mode. The mark is how that reaches the next Stop; everything the recording
# would have decided stays undecided.
state_without_mark() {  # <state-file> -> canonical JSON of everything but the mark
  python3 -c '
import json, sys

with open(sys.argv[1]) as f:
    state = json.load(f)
state.pop("record_failed", None)
state.pop("record_failed_reason", None)
print(json.dumps(state, sort_keys=True))
' "$1" 2>/dev/null
}

PROJ=$(new_proj)
ORPHAN=$(orphan_hook)
assistant_jsonl "$PROJ/transcript.jsonl" '<verdict>BLOCK</verdict>'
ERR=$(printf '%s' "$(subagent_stop_json reviewer "$PROJ/transcript.jsonl")" \
  | CLAUDE_PROJECT_DIR="$PROJ" bash "$ORPHAN/.claude/hooks/$R" 2>&1 >/dev/null)
RC=$?
MARKED=$(state_field "$PROJ/$STATE_REL" record_failed)
REASON=$(state_field "$PROJ/$STATE_REL" record_failed_reason)
REST=$(state_without_mark "$PROJ/$STATE_REL")
rm -rf "$ORPHAN" "$PROJ"
# `{}` is the whole point: the mark arrives alone. A last_verdict or an attempt
# invented here would be a judgement the hook never read.
if [ "$RC" -eq 0 ] && [ "$MARKED" = "True" ] && [ -n "$REASON" ] && [ "$REST" = "{}" ] \
   && printf '%s' "$ERR" | grep -qi 'WARNING'; then
  report 0 "$R" "the verdict parser cannot run -> the failure is marked and nothing else, exit 0"
else
  report 1 "$R" "the verdict parser cannot run -> the failure is marked and nothing else, exit 0 (rc=$RC marked=$MARKED reason='$REASON' rest=$REST err='$ERR')"
fi

# The same with a budget already in flight, which is when it matters: a review
# mid-loop has two of its three attempts spent, and a hook that cannot read the
# verdict has no business touching any of that. Compared as canonical JSON with
# the mark removed — a rewrite that happens to preserve the values still means
# the hook decided something it had no basis to decide.
PROJ=$(new_proj)
ORPHAN=$(orphan_hook)
assistant_jsonl "$PROJ/transcript.jsonl" '<verdict>BLOCK</verdict>'
printf '{"last_verdict":"BLOCK","attempt":2,"enforced":true,"last_diff_sha":"deadbeef"}\n' > "$PROJ/$STATE_REL"
BEFORE=$(state_without_mark "$PROJ/$STATE_REL")
ERR=$(printf '%s' "$(subagent_stop_json reviewer "$PROJ/transcript.jsonl")" \
  | CLAUDE_PROJECT_DIR="$PROJ" bash "$ORPHAN/.claude/hooks/$R" 2>&1 >/dev/null)
RC=$?
AFTER=$(state_without_mark "$PROJ/$STATE_REL")
MARKED=$(state_field "$PROJ/$STATE_REL" record_failed)
rm -rf "$ORPHAN" "$PROJ"
if [ "$RC" -eq 0 ] && [ "$AFTER" = "$BEFORE" ] && [ "$MARKED" = "True" ] \
   && printf '%s' "$ERR" | grep -qi 'WARNING'; then
  report 0 "$R" "the verdict parser cannot run -> an in-flight budget is untouched but marked"
else
  report 1 "$R" "the verdict parser cannot run -> an in-flight budget is untouched but marked (rc=$RC before=$BEFORE after=$AFTER marked=$MARKED err='$ERR')"
fi

# Every other way a reviewer's verdict can fail to be recorded. Each of these
# used to end in a warning on stderr and nothing else, which is the silence the
# mark exists to break — and none of them may invent a verdict on the way.
mark_only_case() {  # <desc> <payload-transcript-path>
  local desc="$1" tpath="$2" proj rc=0 marked rest
  proj=$(new_proj)
  printf '%s' "$(subagent_stop_json reviewer "$tpath")" \
    | CLAUDE_PROJECT_DIR="$proj" bash "$HOOKS_DIR/$R" >/dev/null 2>&1 || rc=$?
  marked=$(state_field "$proj/$STATE_REL" record_failed)
  rest=$(state_without_mark "$proj/$STATE_REL")
  rm -rf "$proj"
  if [ "$rc" -eq 0 ] && [ "$marked" = "True" ] && [ "$rest" = "{}" ]; then
    report 0 "$R" "$desc"
  else
    report 1 "$R" "$desc (rc=$rc marked=$marked rest=$rest)"
  fi
}

mark_only_case "a transcript path that does not exist -> the failure is marked" \
  /nonexistent/transcript.jsonl
mark_only_case "a payload with no agent_transcript_path -> the failure is marked" ''

# A reviewer whose verdict was recorded is not a failure, and the mark has to go
# with it: a parser that broke once and works now must not keep announcing the
# time it broke.
PROJ=$(new_proj)
ORPHAN=$(orphan_hook)
assistant_jsonl "$PROJ/transcript.jsonl" '<verdict>BLOCK</verdict>'
printf '%s' "$(subagent_stop_json reviewer "$PROJ/transcript.jsonl")" \
  | CLAUDE_PROJECT_DIR="$PROJ" bash "$ORPHAN/.claude/hooks/$R" >/dev/null 2>&1
MARKED_BEFORE=$(state_field "$PROJ/$STATE_REL" record_failed)
record_run "$PROJ" "$(subagent_stop_json reviewer "$PROJ/transcript.jsonl")" >/dev/null
MARKED_AFTER=$(state_field "$PROJ/$STATE_REL" record_failed)
REASON_AFTER=$(state_field "$PROJ/$STATE_REL" record_failed_reason)
GOT_V=$(state_field "$PROJ/$STATE_REL" last_verdict)
rm -rf "$ORPHAN" "$PROJ"
if [ "$MARKED_BEFORE" = "True" ] && [ -z "$MARKED_AFTER" ] && [ -z "$REASON_AFTER" ] \
   && [ "$GOT_V" = "BLOCK" ]; then
  report 0 "$R" "a recording that works again clears the mark the broken one left"
else
  report 1 "$R" "a recording that works again clears the mark the broken one left (before=$MARKED_BEFORE after=$MARKED_AFTER reason='$REASON_AFTER' verdict=$GOT_V)"
fi

# Nobody but a reviewer can mark anything. A coder stopping in a project that
# never ran a review would otherwise create a state file out of nothing, and
# enforce-loop.sh reads the existence of that file as "a loop is in flight".
PROJ=$(new_proj)
RC=$(record_run "$PROJ" "$(subagent_stop_json coder /nonexistent/transcript.jsonl)")
if [ "$RC" -eq 0 ] && [ ! -f "$PROJ/$STATE_REL" ]; then
  report 0 "$R" "a non-reviewer that could not be read marks nothing"
else
  report 1 "$R" "a non-reviewer that could not be read marks nothing (rc=$RC)"
fi
rm -rf "$PROJ"

# The empty string is the one value last_verdict must never take, whatever the
# parser did. It is not a harmless placeholder: record_state counts "" as a
# judgement and spends an attempt, while enforce-loop.sh finds no verdict it
# recognises and releases the turn. One empty write burns a retry and switches
# enforcement off in the same breath, which is why this is swept rather than
# spot-checked — the exit code and the printed word fail independently.
EMPTY_WRITES=""
STATE_TOUCHED=""
UNMARKED=""
state_verdict_shape() {  # <state-file> -> no-file | absent | empty | <the value>
  python3 -c '
import json, sys

try:
    with open(sys.argv[1]) as f:
        state = json.load(f)
except Exception:
    print("no-file"); raise SystemExit(0)
if not isinstance(state, dict) or "last_verdict" not in state:
    print("absent")
else:
    print(state["last_verdict"] if str(state["last_verdict"]) else "empty")
' "$1" 2>/dev/null
}
run_stubbed_parser() {  # <label> <hook-path> <proj> <state-before>
  # Every parser this is called with failed to produce a verdict, so both of the
  # hook's two guards are under test at once: the exit code and the word on
  # stdout can fail independently, and neither may reach the state file. The
  # failure mark is the one thing that is allowed to appear, so it is compared
  # out of the way and then required.
  local label="$1" hook="$2" proj="$3" before="$4" got after
  printf '%s' "$(subagent_stop_json reviewer "$proj/transcript.jsonl")" \
    | CLAUDE_PROJECT_DIR="$proj" bash "$hook" >/dev/null 2>&1
  after=$(state_without_mark "$proj/$STATE_REL")
  [ "$after" = "$before" ] || STATE_TOUCHED="$STATE_TOUCHED|$label -> $after"
  [ "$(state_field "$proj/$STATE_REL" record_failed)" = "True" ] \
    || UNMARKED="$UNMARKED|$label"
  # state_field cannot tell an absent key from an empty one, and the difference
  # is the whole invariant: absent (or the seeded value, left alone) means the
  # hook decided nothing, while "" means it spent an attempt on a verdict it
  # never read. What was or was not invented is the comparison above.
  got=$(state_verdict_shape "$proj/$STATE_REL")
  [ "$got" = "empty" ] && EMPTY_WRITES="$EMPTY_WRITES|$label -> last_verdict $got"
  return 0
}

# Each parser below is a way for run_phase.py to come back with no verdict:
# absent, silent, talkative but unrecognisable, or a real verdict word carried
# out on an exit code that does not mean what it says.
while IFS='|' read -r STUB_LABEL STUB_BODY; do
  [ -n "$STUB_LABEL" ] || continue
  for SEED in - '{"last_verdict":"BLOCK","attempt":1}'; do
    PROJ=$(new_proj)
    assistant_jsonl "$PROJ/transcript.jsonl" '<verdict>BLOCK</verdict>'
    SEED_LABEL="on a fresh project"
    BEFORE="{}"  # a fresh project: with the mark compared away, nothing is left
    if [ "$SEED" != "-" ]; then
      printf '%s\n' "$SEED" > "$PROJ/$STATE_REL"
      BEFORE=$(state_without_mark "$PROJ/$STATE_REL")
      SEED_LABEL="mid-budget"
    fi
    if [ "$STUB_BODY" = "-" ]; then ORPHAN=$(orphan_hook); else ORPHAN=$(orphan_hook "$STUB_BODY"); fi
    run_stubbed_parser "$STUB_LABEL, $SEED_LABEL" "$ORPHAN/.claude/hooks/$R" "$PROJ" "$BEFORE"
    rm -rf "$ORPHAN" "$PROJ"
  done
done <<'STUBS'
no run_phase.py at all|-
a parser that prints nothing and exits 0|import sys; sys.exit(0)
a parser that prints an unknown word|print("LGTM")
a verdict word on an exit code that carries none|import sys; print("BLOCK"); sys.exit(3)
a parser that crashes|raise RuntimeError("boom")
STUBS

if [ -z "$EMPTY_WRITES" ]; then
  report 0 "$R" "last_verdict is never written as an empty string"
else
  report 1 "$R" "last_verdict is never written as an empty string (empty after: $EMPTY_WRITES)"
fi

if [ -z "$STATE_TOUCHED" ]; then
  report 0 "$R" "no parser failure of any shape edits anything but the mark"
else
  report 1 "$R" "no parser failure of any shape edits anything but the mark ($STATE_TOUCHED)"
fi

if [ -z "$UNMARKED" ]; then
  report 0 "$R" "every shape of parser failure leaves the mark behind"
else
  report 1 "$R" "every shape of parser failure leaves the mark behind (unmarked: $UNMARKED)"
fi

# ---------- record-verdict.sh : it has to find its own parser ----------
# The hook looks up run_phase.py next to itself, so how it was invoked decides
# whether it finds it at all. settings.json uses an absolute path, but a
# wrapper, a CI step or a hand run does not have to — and when the lookup
# misses, the guard above is the only thing between a typo and a lost attempt.
# These cases keep the trigger fixed rather than only its blast radius.

REPO_ROOT=$(cd "$HOOKS_DIR/../.." && pwd)

invocation_case() {  # <desc> <cwd> <hook-as-invoked>
  local desc="$1" cwd="$2" as="$3" proj rc=0 got_v got_a
  proj=$(new_proj)
  assistant_jsonl "$proj/transcript.jsonl" '<verdict>BLOCK</verdict>'
  ( cd "$cwd" && printf '%s' "$(subagent_stop_json reviewer "$proj/transcript.jsonl")" \
      | CLAUDE_PROJECT_DIR="$proj" bash "$as" >/dev/null 2>&1 ) || rc=$?
  got_v=$(state_field "$proj/$STATE_REL" last_verdict)
  got_a=$(state_field "$proj/$STATE_REL" attempt)
  rm -rf "$proj"
  if [ "$rc" -eq 0 ] && [ "$got_v" = "BLOCK" ] && [ "$got_a" = "1" ]; then
    report 0 "$R" "$desc"
  else
    report 1 "$R" "$desc (rc=$rc, got $got_v/$got_a, want BLOCK/1)"
  fi
}

# `bash record-verdict.sh` from the hooks directory: $0 carries no slash, so
# stripping a directory component off it leaves the file name itself.
invocation_case "invoked by bare name from the hooks dir -> records BLOCK, attempt 1" \
  "$HOOKS_DIR" "$R"

# Through a symlink the parser lives next to the real file, not next to the link.
SYMDIR=$(mktemp -d /tmp/hooktest-symlink-XXXXXX)
ln -s "$HOOKS_DIR/$R" "$SYMDIR/hook.sh"
invocation_case "invoked through a symlink -> records BLOCK, attempt 1" \
  "$SYMDIR" "$SYMDIR/hook.sh"
rm -rf "$SYMDIR"

# The two forms that already worked. They are the ones the fix could plausibly
# break, so they are asserted rather than assumed: settings.json invokes the
# hook by absolute path, and a relative path is what a hand run types.
invocation_case "invoked by absolute path -> records BLOCK, attempt 1" \
  "$REPO_ROOT" "$HOOKS_DIR/$R"
invocation_case "invoked by relative path from the repo root -> records BLOCK, attempt 1" \
  "$REPO_ROOT" ".claude/hooks/$R"

# ---------- both hooks : CLAUDE_PROJECT_DIR is not guaranteed ----------
# Hooks are invoked with the variable set, but a wrapper script, a manual run or
# a test harness can drop it. Neither hook may crash, and neither may reach for
# a path outside the directory it was started in.
PROJ=$(mktemp -d /tmp/hooktest-proj-XXXXXX)
assistant_jsonl "$PROJ/transcript.jsonl" '<verdict>BLOCK</verdict>'
RC=0
( cd "$PROJ" && printf '%s' "$(subagent_stop_json reviewer "$PROJ/transcript.jsonl")" \
  | env -u CLAUDE_PROJECT_DIR bash "$HOOKS_DIR/$R" >/dev/null 2>&1 ) || RC=$?
if [ "$RC" -eq 0 ] && [ "$(state_field "$PROJ/$STATE_REL" last_verdict)" = "BLOCK" ]; then
  report 0 "$R" "no CLAUDE_PROJECT_DIR -> falls back to the cwd, exit 0"
else
  report 1 "$R" "no CLAUDE_PROJECT_DIR -> falls back to the cwd, exit 0 (rc=$RC)"
fi

# The same fallback on the judging side: the state it just wrote is the state it
# now reads, and a cwd with no state file is an ordinary turn, not a loop.
RC=0
( cd "$PROJ" && printf '%s' "$(stop_json)" \
  | env -u CLAUDE_PROJECT_DIR bash "$HOOKS_DIR/$E" >/dev/null 2>&1 ) || RC=$?
RC_ELSEWHERE=0
EMPTY_CWD=$(mktemp -d /tmp/hooktest-cwd-XXXXXX)
( cd "$EMPTY_CWD" && printf '%s' "$(stop_json)" \
  | env -u CLAUDE_PROJECT_DIR bash "$HOOKS_DIR/$E" >/dev/null 2>&1 ) || RC_ELSEWHERE=$?
rm -rf "$EMPTY_CWD" "$PROJ"
if [ "$RC" -eq 2 ] && [ "$RC_ELSEWHERE" -eq 0 ]; then
  report 0 "$E" "no CLAUDE_PROJECT_DIR -> reads the cwd's state, and only the cwd's"
else
  report 1 "$E" "no CLAUDE_PROJECT_DIR -> reads the cwd's state, and only the cwd's (rc=$RC elsewhere=$RC_ELSEWHERE)"
fi

# ---------- enforce-loop.sh : every unusable state releases the turn ----------
# A Stop hook that holds a turn on a value it cannot interpret cannot be talked
# out of it — there is no turn left in which to fix the file. So each of these
# has to end with the turn released, and loudly enough that the user learns the
# budget stopped being counted.
enforce_case 0 "negative attempt -> exit 0 + warning" \
  '{"last_verdict":"BLOCK","attempt":-1}' "$(stop_json)" 'WARNING' -
enforce_case 0 "fractional attempt -> exit 0 + warning" \
  '{"last_verdict":"BLOCK","attempt":1.5}' "$(stop_json)" 'WARNING' -
enforce_case 0 "attempt written as a boolean -> exit 0 + warning" \
  '{"last_verdict":"BLOCK","attempt":true}' "$(stop_json)" 'WARNING' -

# All digits and still uncountable: `[ n -ge 3 ]` compares as a signed 64-bit
# integer, so a longer number kills the test itself. A dead test is false, which
# reads as "budget left" — the turn would be held on a number nobody can count,
# with bash's own error on stderr alongside.
enforce_case 0 "attempt past 64-bit -> exit 0 + warning" \
  '{"last_verdict":"BLOCK","attempt":99999999999999999999}' "$(stop_json)" 'WARNING' -
enforce_case 0 "attempt one past the signed 64-bit ceiling -> exit 0 + warning" \
  '{"last_verdict":"BLOCK","attempt":9223372036854775808}' "$(stop_json)" 'WARNING' -

# An absent or null attempt is a different event from an unreadable one: nothing
# says the counter is broken, only that no attempt has been recorded yet. It
# reads as 0, so the turn continues on 0/3 and the next reviewer run writes a
# real number. stop_hook_active caps this at one extra turn either way.
enforce_case 2 "absent attempt counts as none spent -> exit 2 at 0/3" \
  '{"last_verdict":"BLOCK"}' "$(stop_json)" 'attempt 0/3' -
enforce_case 2 "null attempt counts as none spent -> exit 2 at 0/3" \
  '{"last_verdict":"BLOCK","attempt":null}' "$(stop_json)" 'attempt 0/3' -

# A verdict this hook does not recognise is not a failed review, so it ends the
# turn — and silently, because "the reviewer never judged" is the documented
# Phase 1 fallback, not an anomaly worth a warning on every legacy run.
enforce_quiet_case() {  # <expected-exit> <desc> <state> [PATH]
  local expected="$1" desc="$2" state="$3" path="${4:-$PATH}"
  local proj out msg err rc=0 ok=0
  proj=$(new_proj)
  printf '%s\n' "$state" > "$proj/$STATE_REL"
  err=$(mktemp /tmp/hooktest-err-XXXXXX)
  out=$(printf '%s' "$(stop_json)" \
    | env PATH="$path" CLAUDE_PROJECT_DIR="$proj" /bin/bash "$HOOKS_DIR/$E" 2>"$err") || rc=$?
  msg=$(cat "$err"); rm -f "$err"; rm -rf "$proj"
  [ "$rc" -eq "$expected" ] && [ -z "$msg" ] && [ -z "$out" ] || ok=1
  if [ "$ok" -eq 0 ]; then
    report 0 "$E" "$desc"
  else
    report 1 "$E" "$desc (rc=$rc out='$out' err='$msg')"
  fi
}

enforce_quiet_case 0 "absent last_verdict -> exit 0, quietly" '{"attempt":1}'
enforce_quiet_case 0 "null last_verdict -> exit 0, quietly" '{"last_verdict":null,"attempt":1}'
enforce_quiet_case 0 "an unknown verdict word -> exit 0, quietly" \
  '{"last_verdict":"LGTM","attempt":1}'
enforce_quiet_case 0 "BLOCKED is not BLOCK -> exit 0, quietly" \
  '{"last_verdict":"BLOCKED","attempt":1}'

# A zero-byte state file is what an interrupted write leaves. It is not an
# object, so it goes down the same path as a truncated one.
PROJ=$(new_proj)
: > "$PROJ/$STATE_REL"
ERR=$(printf '%s' "$(stop_json)" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOKS_DIR/$E" 2>&1 >/dev/null)
RC=$?
rm -rf "$PROJ"
if [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -qi 'WARNING'; then
  report 0 "$E" "zero-byte loop-state.json -> exit 0 + warning"
else
  report 1 "$E" "zero-byte loop-state.json -> exit 0 + warning (rc=$RC err='$ERR')"
fi

# A directory where the state file belongs never reaches a reader: the `-f`
# guard that keeps ordinary chat out of this hook catches it first, and quietly,
# because that guard fires on every non-loop turn there is.
PROJ=$(new_proj)
mkdir -p "$PROJ/$STATE_REL"
RC=0
OUT=$(printf '%s' "$(stop_json)" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOKS_DIR/$E" 2>&1) || RC=$?
rm -rf "$PROJ"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  report 0 "$E" "loop-state.json is a directory -> exit 0, quietly"
else
  report 1 "$E" "loop-state.json is a directory -> exit 0, quietly (rc=$RC out='$OUT')"
fi

# chmod 000 does not stop root, so the case would assert nothing there.
if [ "$(id -u)" -eq 0 ]; then
  report 0 "$E" "unreadable loop-state.json -> exit 0 + warning (skipped: running as root)"
else
  PROJ=$(new_proj)
  printf '{"last_verdict":"BLOCK","attempt":1}\n' > "$PROJ/$STATE_REL"
  chmod 000 "$PROJ/$STATE_REL"
  ERR=$(printf '%s' "$(stop_json)" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOKS_DIR/$E" 2>&1 >/dev/null)
  RC=$?
  chmod 600 "$PROJ/$STATE_REL"; rm -rf "$PROJ"
  if [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -qi 'WARNING'; then
    report 0 "$E" "unreadable loop-state.json -> exit 0 + warning"
  else
    report 1 "$E" "unreadable loop-state.json -> exit 0 + warning (rc=$RC err='$ERR')"
  fi
fi

# Which reader a host happens to have must not change any of these answers. The
# numeric guard is the one worth re-running on both: jq and python3 render the
# same JSON number differently, and the guard reads the rendering, not the JSON.
EDGE_NOJQ=$(mktemp -d /tmp/hooktest-nojq-XXXXXX)
ln -s "$REAL_PY" "$EDGE_NOJQ/python3"
ln -s "$(command -v cat)" "$EDGE_NOJQ/cat"
enforce_case 0 "python3 fallback: negative attempt -> exit 0 + warning" \
  '{"last_verdict":"BLOCK","attempt":-1}' "$(stop_json)" 'WARNING' - "$EDGE_NOJQ"
enforce_case 0 "python3 fallback: fractional attempt -> exit 0 + warning" \
  '{"last_verdict":"BLOCK","attempt":1.5}' "$(stop_json)" 'WARNING' - "$EDGE_NOJQ"
enforce_case 0 "python3 fallback: boolean attempt -> exit 0 + warning" \
  '{"last_verdict":"BLOCK","attempt":true}' "$(stop_json)" 'WARNING' - "$EDGE_NOJQ"
enforce_case 2 "python3 fallback: absent attempt -> exit 2 at 0/3" \
  '{"last_verdict":"BLOCK"}' "$(stop_json)" 'attempt 0/3' - "$EDGE_NOJQ"
enforce_case 0 "python3 fallback: an unknown verdict word -> exit 0" \
  '{"last_verdict":"LGTM","attempt":1}' "$(stop_json)" - - "$EDGE_NOJQ"

# The python3 branch prints one field per line, so a newline inside a value
# shifts every later field down a line: last_verdict="BLOCK\n1" would be read as
# a BLOCK on attempt 1 and hold the turn, while jq reads the newline-carrying
# string, finds no verdict it knows and lets the turn end. The two readers have
# to answer the same, and the answer has to be the one that does not trap a
# session on a value the state file never held.
SHIFTED_STATE='{"last_verdict":"BLOCK\n1","attempt":9}'
enforce_case 0 "a newline in last_verdict -> exit 0 (jq)" \
  "$SHIFTED_STATE" "$(stop_json)" - -
enforce_case 0 "a newline in last_verdict -> exit 0 (python3 fallback, same answer)" \
  "$SHIFTED_STATE" "$(stop_json)" - - "$EDGE_NOJQ"

# The two readers disagree about what is true: jq's only falsy values are false
# and null, python's also include 0, "", [] and {}. Every flag this hook reads is
# a boolean, so these values only arrive from a hand-edited state file or a host
# that renders them differently — but "whether jq is installed changes nothing
# else" is the contract, and an `enforced: 0` that looks spent to jq and armed to
# python3 breaks it in the direction that switches enforcement off.
#
# The table has to hold values from BOTH sides of the disagreement. With only
# 0, "", [] and {} in it, the python3 half asserted nothing: python already calls
# those falsy, so the hook's `is True` could be written as a bare truth test and
# every case still passed. 1 and "true" are where the two readers actually part
# company — truthy to python, not `true` to jq — and they are what makes the
# python3 column bite.
for NOT_TRUE in 0 '""' '[]' '{}' 1 '"true"'; do
  ARMED_STATE="{\"last_verdict\":\"BLOCK\",\"attempt\":1,\"enforced\":$NOT_TRUE}"
  enforce_case 2 "enforced: $NOT_TRUE is not true, so the verdict is still armed (jq)" \
    "$ARMED_STATE" "$(stop_json)" 'attempt 1/3' -
  enforce_case 2 "enforced: $NOT_TRUE is not true, so the verdict is still armed (python3 fallback)" \
    "$ARMED_STATE" "$(stop_json)" 'attempt 1/3' - "$EDGE_NOJQ"

  enforce_case 2 "stop_hook_active: $NOT_TRUE is not true, so the budget still bites (jq)" \
    '{"last_verdict":"BLOCK","attempt":1}' "$(stop_json "$NOT_TRUE")" 'attempt 1/3' -
  enforce_case 2 "stop_hook_active: $NOT_TRUE is not true, so the budget still bites (python3 fallback)" \
    '{"last_verdict":"BLOCK","attempt":1}' "$(stop_json "$NOT_TRUE")" 'attempt 1/3' - "$EDGE_NOJQ"

  # The key Phase 3 added inherits the rule. Announcing on a mangled flag would
  # be the same failure pointed the other way: a fact reported out of a file
  # that never carried it.
  MARK_STATE="{\"record_failed\":$NOT_TRUE,\"record_failed_reason\":\"nothing happened\"}"
  enforce_quiet_case 0 "record_failed: $NOT_TRUE is not true, so nothing is announced (jq)" \
    "$MARK_STATE"
  enforce_quiet_case 0 "record_failed: $NOT_TRUE is not true, so nothing is announced (python3 fallback)" \
    "$MARK_STATE" "$EDGE_NOJQ"
done
rm -rf "$EDGE_NOJQ"

# The same shift in record-verdict.sh is worse: a newline in agent_type pushes
# the transcript path up a line, so the hook reads a file the payload never
# named as the reviewer's transcript and records a verdict out of it.
RECORD_NOJQ=$(mktemp -d /tmp/hooktest-nojq-rec-XXXXXX)
ln -s "$REAL_PY" "$RECORD_NOJQ/python3"
for BIN in cat mktemp rm mkdir; do ln -s "$(command -v "$BIN")" "$RECORD_NOJQ/$BIN"; done

record_run_with_path() {  # <proj> <payload> <PATH> -> exit code
  local proj="$1" payload="$2" path="$3" rc=0
  printf '%s' "$payload" \
    | env PATH="$path" CLAUDE_PROJECT_DIR="$proj" /bin/bash "$HOOKS_DIR/$R" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

PROJ=$(new_proj)
assistant_jsonl "$PROJ/never-named.jsonl" '<verdict>BLOCK</verdict>'
assistant_jsonl "$PROJ/named.jsonl" '<verdict>APPROVE</verdict>'
# \n stays a JSON escape: the payload is one JSON object on one physical line.
SHIFTED_PAYLOAD=$(printf '{"hook_event_name":"SubagentStop","agent_type":"reviewer\\n%s","agent_transcript_path":"%s"}' \
  "$PROJ/never-named.jsonl" "$PROJ/named.jsonl")
JQ_RC=$(record_run "$PROJ" "$SHIFTED_PAYLOAD")
JQ_STATE=absent
[ -f "$PROJ/$STATE_REL" ] && JQ_STATE=$(cat "$PROJ/$STATE_REL")
rm -f "$PROJ/$STATE_REL"
PY_RC=$(record_run_with_path "$PROJ" "$SHIFTED_PAYLOAD" "$RECORD_NOJQ")
PY_STATE=absent
[ -f "$PROJ/$STATE_REL" ] && PY_STATE=$(cat "$PROJ/$STATE_REL")
rm -rf "$PROJ" "$RECORD_NOJQ"
if [ "$JQ_RC" -eq 0 ] && [ "$PY_RC" -eq 0 ] \
   && [ "$JQ_STATE" = absent ] && [ "$PY_STATE" = absent ]; then
  report 0 "$R" "a newline in agent_type reads no other file, whichever reader runs"
else
  report 1 "$R" "a newline in agent_type reads no other file, whichever reader runs (jq=$JQ_RC/$JQ_STATE py=$PY_RC/$PY_STATE)"
fi

# ---------- the two hooks : an APPROVE mid-budget really does reset it ----------
# The end-to-end case above walks the budget to exhaustion. This one interrupts
# it: if the reset were only written to the file but not honoured on the next
# BLOCK, the loop would still die early — the counter has to start at 1 again,
# and the turn has to be blocked rather than handed to a human.
PROJ=$(new_proj)
assistant_jsonl "$PROJ/block.jsonl" '<verdict>BLOCK</verdict>'
assistant_jsonl "$PROJ/approve.jsonl" '<verdict>APPROVE</verdict>'
record_run "$PROJ" "$(subagent_stop_json reviewer "$PROJ/block.jsonl")" >/dev/null
record_run "$PROJ" "$(subagent_stop_json reviewer "$PROJ/block.jsonl")" >/dev/null
record_run "$PROJ" "$(subagent_stop_json reviewer "$PROJ/approve.jsonl")" >/dev/null
record_run "$PROJ" "$(subagent_stop_json reviewer "$PROJ/block.jsonl")" >/dev/null
RC=0
OUT=$(printf '%s' "$(stop_json)" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOKS_DIR/$E" 2>&1) || RC=$?
GOT_A=$(state_field "$PROJ/$STATE_REL" attempt)
rm -rf "$PROJ"
if [ "$RC" -eq 2 ] && [ "$GOT_A" = "1" ] && printf '%s' "$OUT" | grep -qF 'attempt 1/3'; then
  report 0 "loop" "BLOCK, BLOCK, APPROVE, BLOCK -> the budget restarts at 1/3"
else
  report 1 "loop" "BLOCK, BLOCK, APPROVE, BLOCK -> the budget restarts at 1/3 (rc=$RC attempt=$GOT_A out='$OUT')"
fi

# A reviewer that quoted a tag and never judged spends nothing and stops nothing:
# the round trip has to leave the budget exactly where it found it and let the
# turn end, which is the pre-hook behaviour Phase 1 deliberately kept open.
PROJ=$(new_proj)
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"개선안: <verdict>BLOCK</verdict> 를 붙일 것\n\n리뷰 계속"}]}}\n' \
  > "$PROJ/transcript.jsonl"
printf '{"last_verdict":"APPROVE","attempt":0}\n' > "$PROJ/$STATE_REL"
record_run "$PROJ" "$(subagent_stop_json reviewer "$PROJ/transcript.jsonl")" >/dev/null
RC=0
printf '%s' "$(stop_json)" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOKS_DIR/$E" >/dev/null 2>&1 || RC=$?
GOT_V=$(state_field "$PROJ/$STATE_REL" last_verdict)
GOT_A=$(state_field "$PROJ/$STATE_REL" attempt)
rm -rf "$PROJ"
if [ "$RC" -eq 0 ] && [ "$GOT_V" = "UNKNOWN" ] && [ "$GOT_A" = "0" ]; then
  report 0 "loop" "a quoted tag with no judgement -> UNKNOWN, budget untouched, turn ends"
else
  report 1 "loop" "a quoted tag with no judgement -> UNKNOWN, budget untouched, turn ends (rc=$RC got $GOT_V/$GOT_A)"
fi

# ---------- enforce-loop.sh : a recording that failed gets said out loud ----------
# record-verdict.sh marks the state file when a reviewer's verdict never reached
# it. This is the half that reaches a human: once, on the next turn, and then
# never again. It is a fact, not a task — re-dispatching a coder would not fix a
# parser — so it releases the turn.

FAILED_MARK='{"record_failed":true,"record_failed_reason":"run_phase.py exited 3 without a verdict"}'

enforce_case 0 "a marked recording failure -> exit 0, the turn is never held" \
  "$FAILED_MARK" "$(stop_json)" - '기록되지'
enforce_case 0 "a marked recording failure -> stdout carries the reason recorded" \
  "$FAILED_MARK" "$(stop_json)" - 'run_phase.py exited 3 without a verdict'

# Said once. Nothing ages the state file out, so a mark left by a session the
# user walked away from would otherwise greet every message in every session
# after it — the same rule the verdict itself follows.
PROJ=$(new_proj)
printf '%s\n' "$FAILED_MARK" > "$PROJ/$STATE_REL"
OUT1=$(abandoned_turn "$PROJ" s1); RC1=$?
OUT2=$(abandoned_turn "$PROJ" a-later-session); RC2=$?
MARKED=$(state_field "$PROJ/$STATE_REL" record_failed)
rm -rf "$PROJ"
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && printf '%s' "$OUT1" | grep -qF '기록되지' \
   && [ -z "$OUT2" ] && [ -z "$MARKED" ]; then
  report 0 "$E" "a recording failure is announced once and then consumed"
else
  report 1 "$E" "a recording failure is announced once and then consumed (rc=$RC1/$RC2 out1='$OUT1' out2='$OUT2' marked='$MARKED')"
fi

# A mark can land on top of a verdict nobody has answered yet: the reviewer of
# cycle 2 failed to record while cycle 1's BLOCK was still armed. The
# announcement takes this turn and spends only itself — the BLOCK stays armed and
# the next turn re-dispatches on it, because a verdict nobody reacted to is
# exactly what the consume-once mark exists to protect.
PROJ=$(new_proj)
printf '{"last_verdict":"BLOCK","attempt":1,"enforced":false,"record_failed":true,"record_failed_reason":"parser died"}\n' \
  > "$PROJ/$STATE_REL"
OUT1=$(abandoned_turn "$PROJ" s1); RC1=$?
ENFORCED_AFTER=$(state_field "$PROJ/$STATE_REL" enforced)
RC2=$(later_turn "$PROJ" s1)
rm -rf "$PROJ"
if [ "$RC1" -eq 0 ] && printf '%s' "$OUT1" | grep -qF '기록되지' \
   && [ "$ENFORCED_AFTER" = "False" ] && [ "$RC2" -eq 2 ]; then
  report 0 "$E" "announcing a failure does not spend the verdict underneath it"
else
  report 1 "$E" "announcing a failure does not spend the verdict underneath it (rc=$RC1/$RC2 enforced=$ENFORCED_AFTER out='$OUT1')"
fi

# End to end, with a parser that really cannot run: the reviewer stops, nothing
# is recorded, and the next turn says so. The seeded cases above would all pass
# on a mark the two hooks spell differently.
PROJ=$(new_proj)
ORPHAN=$(orphan_hook)
assistant_jsonl "$PROJ/transcript.jsonl" '<verdict>BLOCK</verdict>'
printf '%s' "$(subagent_stop_json reviewer "$PROJ/transcript.jsonl")" \
  | CLAUDE_PROJECT_DIR="$PROJ" bash "$ORPHAN/.claude/hooks/$R" >/dev/null 2>&1
OUT1=$(abandoned_turn "$PROJ" s1); RC1=$?
OUT2=$(abandoned_turn "$PROJ" s1); RC2=$?
rm -rf "$ORPHAN" "$PROJ"
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] \
   && printf '%s' "$OUT1" | grep -qF '기록되지' && [ -z "$OUT2" ]; then
  report 0 "loop" "a reviewer whose verdict could not be recorded is reported on the next turn"
else
  report 1 "loop" "a reviewer whose verdict could not be recorded is reported on the next turn (rc=$RC1/$RC2 out1='$OUT1' out2='$OUT2')"
fi

# The same interleaving as the verdict race, on the other mark: a reviewer can
# fail to record while this hook is announcing the previous failure. Consuming
# whatever is on disk would swallow a failure nobody has read, and that one is
# gone for good — nothing re-announces it, because the reviewer that would have
# re-marked it has already stopped.
PROJ=$(new_proj)
printf '{"record_failed":true,"record_failed_reason":"the first failure"}\n' > "$PROJ/$STATE_REL"
CLEAR_BIN=$(mktemp -d /tmp/hooktest-clear-XXXXXX)
cat > "$CLEAR_BIN/python3" <<EOF
#!/bin/bash
# Fires when the hook is about to clear the mark it announced, and not on its
# other python3 calls: the edit mode is the first argument after the \`-\`.
[ "\${2-}" = "clear-record-failure" ] && printf '{"record_failed":true,"record_failed_reason":"a second, later failure"}\n' > "$PROJ/$STATE_REL"
exec "$REAL_PY" "\$@"
EOF
chmod +x "$CLEAR_BIN/python3"
RC=0
OUT=$(printf '%s' "$(stop_json)" \
  | env PATH="$CLEAR_BIN:$PATH" CLAUDE_PROJECT_DIR="$PROJ" /bin/bash "$HOOKS_DIR/$E" 2>/dev/null) || RC=$?
STILL_MARKED=$(state_field "$PROJ/$STATE_REL" record_failed)
STILL_REASON=$(state_field "$PROJ/$STATE_REL" record_failed_reason)
rm -rf "$PROJ" "$CLEAR_BIN"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'the first failure' \
   && [ "$STILL_MARKED" = "True" ] && [ "$STILL_REASON" = "a second, later failure" ]; then
  report 0 "$E" "a failure that landed after the read is left unannounced, not consumed"
else
  report 1 "$E" "a failure that landed after the read is left unannounced, not consumed (rc=$RC marked=$STILL_MARKED reason='$STILL_REASON' out='$OUT')"
fi

# An unreadable state file cannot be un-marked, so it keeps the warning it had.
# Announcing out of a file this hook could not parse would be inventing a fact.
enforce_case 0 "a truncated state file is still just a warning -> exit 0" \
  '{"record_failed":' "$(stop_json)" 'WARNING' -

# Whichever reader the host has.
FAILED_NOJQ=$(mktemp -d /tmp/hooktest-nojq-rf-XXXXXX)
ln -s "$REAL_PY" "$FAILED_NOJQ/python3"
ln -s "$(command -v cat)" "$FAILED_NOJQ/cat"
enforce_case 0 "python3 fallback: a marked recording failure -> exit 0 + the reason" \
  "$FAILED_MARK" "$(stop_json)" - 'run_phase.py exited 3 without a verdict' "$FAILED_NOJQ"
rm -rf "$FAILED_NOJQ"

# ---------- enforce-loop.sh : a loop that is not moving stops early ----------
# The budget of 3 bounds how long a stalled loop runs, it does not notice that
# it is stalled. Two cycles over an identical tree buy identical attempts, so
# the remaining budget is worth nothing — and the reviewer has already said
# twice what is wrong.

SAME_FP='{"last_verdict":"BLOCK","attempt":1,"last_diff_sha":"deadbeef","prev_diff_sha":"deadbeef"}'
MOVED_FP='{"last_verdict":"BLOCK","attempt":1,"last_diff_sha":"deadbeef","prev_diff_sha":"cafebabe"}'

enforce_case 0 "no progress since the last cycle -> exit 0, budget left unspent" \
  "$SAME_FP" "$(stop_json)" '무진전' -
enforce_case 0 "no progress -> stderr counts the attempt it stopped at (1/3)" \
  "$SAME_FP" "$(stop_json)" 'attempt 1/3' -
# Same rule as the exhausted budget: exit 0 is "stop", not "passed", so the
# stdout the user reads has to say a human is needed.
enforce_case 0 "no progress -> stdout asks for a human, not a success" \
  "$SAME_FP" "$(stop_json)" - '사람 개입'

# The other half of the same branch, and the one that must not regress: a tree
# that moved is a coder that did something, and the budget is there to be spent.
enforce_case 2 "the tree moved since the last cycle -> exit 2, re-dispatch as before" \
  "$MOVED_FP" "$(stop_json)" 'attempt 1/3' -

# The first cycle of a loop has nothing behind it. Reading an absent or empty
# previous fingerprint as "equal" would stop every loop on its first BLOCK,
# which is the whole feature failing closed.
enforce_case 2 "no fingerprints at all (first cycle) -> exit 2, not no-progress" \
  '{"last_verdict":"BLOCK","attempt":1}' "$(stop_json)" 'attempt 1/3' -
enforce_case 2 "a fingerprint with no previous one -> exit 2, not no-progress" \
  '{"last_verdict":"BLOCK","attempt":1,"last_diff_sha":"deadbeef","prev_diff_sha":""}' \
  "$(stop_json)" 'attempt 1/3' -
# Both empty is the shape a project outside a git repo leaves behind. Two
# unknowns are not the same tree.
enforce_case 2 "two empty fingerprints -> exit 2, not no-progress" \
  '{"last_verdict":"BLOCK","attempt":1,"last_diff_sha":"","prev_diff_sha":""}' \
  "$(stop_json)" 'attempt 1/3' -

# An exhausted budget keeps its own message: it is the more accurate one, and
# nothing about no-progress changes what happens at 3/3.
enforce_case 0 "no progress with the budget already spent -> the exhaustion banner still" \
  '{"last_verdict":"BLOCK","attempt":3,"last_diff_sha":"deadbeef","prev_diff_sha":"deadbeef"}' \
  "$(stop_json)" - '3/3'

# Whichever reader the host has, the same two states get the same two answers.
NOPROG_NOJQ=$(mktemp -d /tmp/hooktest-nojq-np-XXXXXX)
ln -s "$REAL_PY" "$NOPROG_NOJQ/python3"
ln -s "$(command -v cat)" "$NOPROG_NOJQ/cat"
enforce_case 0 "python3 fallback: no progress -> exit 0" \
  "$SAME_FP" "$(stop_json)" '무진전' - "$NOPROG_NOJQ"
enforce_case 2 "python3 fallback: the tree moved -> exit 2" \
  "$MOVED_FP" "$(stop_json)" 'attempt 1/3' - "$NOPROG_NOJQ"
rm -rf "$NOPROG_NOJQ"

# ---------- enforce-loop.sh : a fingerprint is a JSON string or it is nothing ----------
# These two keys are the only values in the state file whose *equality* decides
# an exit code, so the readers cannot merely be close — they have to answer the
# same on every shape a file can hold. They have now drifted apart twice, so the
# cases below pin the whole table rather than the shapes that happened to break.
#
# Each case runs the hook twice, once as the host has it and once with jq
# hidden, and requires the same exit code and the same bytes on both streams.
# The two runs get their own project dir on purpose: a run that reacts marks the
# verdict spent, and a spent verdict answers differently, so sharing one dir
# would let the first reader dictate the second reader's answer.
FP_NOJQ=$(mktemp -d /tmp/hooktest-nojq-fp-XXXXXX)
ln -s "$REAL_PY" "$FP_NOJQ/python3"
ln -s "$(command -v cat)" "$FP_NOJQ/cat"

fingerprint_parity_case() {  # <expected-exit> <desc> <state> [want-stderr|-]
  local expected="$1" desc="$2" state="$3" want_err="${4:--}"
  local jq_rc=0 py_rc=0 ok=0 proj
  local jq_out jq_err py_out py_err
  jq_out=$(mktemp /tmp/hooktest-fp-XXXXXX); jq_err=$(mktemp /tmp/hooktest-fp-XXXXXX)
  py_out=$(mktemp /tmp/hooktest-fp-XXXXXX); py_err=$(mktemp /tmp/hooktest-fp-XXXXXX)

  proj=$(new_proj); printf '%s\n' "$state" > "$proj/$STATE_REL"
  printf '%s' "$(stop_json)" \
    | env CLAUDE_PROJECT_DIR="$proj" /bin/bash "$HOOKS_DIR/$E" >"$jq_out" 2>"$jq_err" || jq_rc=$?
  rm -rf "$proj"

  proj=$(new_proj); printf '%s\n' "$state" > "$proj/$STATE_REL"
  printf '%s' "$(stop_json)" \
    | env PATH="$FP_NOJQ" CLAUDE_PROJECT_DIR="$proj" /bin/bash "$HOOKS_DIR/$E" >"$py_out" 2>"$py_err" || py_rc=$?
  rm -rf "$proj"

  [ "$jq_rc" -eq "$py_rc" ] || ok=1
  cmp -s "$jq_out" "$py_out" || ok=1
  cmp -s "$jq_err" "$py_err" || ok=1
  [ "$jq_rc" -eq "$expected" ] || ok=1
  [ "$want_err" = "-" ] || grep -qF "$want_err" "$jq_err" || ok=1
  if [ "$ok" -eq 0 ]; then
    report 0 "$E" "$desc"
  else
    report 1 "$E" "$desc (jq rc=$jq_rc err='$(cat "$jq_err")' | python3 rc=$py_rc err='$(cat "$py_err")')"
  fi
  rm -f "$jq_out" "$jq_err" "$py_out" "$py_err"
}

# record_state only ever writes a string here or leaves the key out, so a number
# is a hand-edited or corrupt file — not a tree anybody measured. jq renders it
# as "0" and finds two equal fingerprints, which stops a loop on a measurement
# that never happened; that is enforcement switching itself off, the exact
# failure this feature exists to prevent. Both readers have to read it as absent
# and let the loop run.
fingerprint_parity_case 2 "both fingerprints are the number 0 -> exit 2 on both readers" \
  '{"last_verdict":"BLOCK","attempt":1,"last_diff_sha":0,"prev_diff_sha":0}' 'attempt 1/3'

# 0 is only where the readers part company; the rest of the table is where they
# agree on the wrong answer. true and 1.5 stop the loop under both readers today
# — same measurement that never happened, no divergence to give it away. The
# rule is a type, not a list of values, so the whole list is written down.
for NOT_A_STRING in '[]' '{}' 'true' '1.5'; do
  fingerprint_parity_case 2 "both fingerprints are $NOT_A_STRING -> exit 2 on both readers" \
    "{\"last_verdict\":\"BLOCK\",\"attempt\":1,\"last_diff_sha\":$NOT_A_STRING,\"prev_diff_sha\":$NOT_A_STRING}" \
    'attempt 1/3'
done

# The feature itself, pinned on both readers rather than one each: a string is
# the only thing that is a fingerprint, so a string is the only thing that can
# stop a loop — and it still must.
fingerprint_parity_case 0 "equal string fingerprints still stop the loop on both readers" \
  "$SAME_FP" '무진전'
fingerprint_parity_case 2 "differing string fingerprints still exit 2 on both readers" \
  "$MOVED_FP" 'attempt 1/3'

# The three shapes that have always meant "not measured" — no git, no repo, or
# the first cycle of a loop — and have to keep meaning it now that the rule is
# written as a type. Reading any of them as a fingerprint would stop every loop
# on its first BLOCK.
fingerprint_parity_case 2 "null fingerprints are no fingerprint on both readers" \
  '{"last_verdict":"BLOCK","attempt":1,"last_diff_sha":null,"prev_diff_sha":null}' 'attempt 1/3'
fingerprint_parity_case 2 "empty-string fingerprints are no fingerprint on both readers" \
  '{"last_verdict":"BLOCK","attempt":1,"last_diff_sha":"","prev_diff_sha":""}' 'attempt 1/3'
fingerprint_parity_case 2 "absent fingerprint keys are no fingerprint on both readers" \
  '{"last_verdict":"BLOCK","attempt":1}' 'attempt 1/3'

# The shapes the readers already agreed on, written down anyway. Agreement that
# nothing asserts is agreement by luck: every one of these travels through a
# different piece of each reader — jq's gsub against python's str.replace, jq -r
# against print, one branch's JSON unescaping against the other's — and the pair
# has now drifted twice with the suite still green.
fingerprint_shape_case() {  # <expected-exit> <label> <json-value>: the same value in both keys
  fingerprint_parity_case "$1" "both readers agree on $2" \
    "{\"last_verdict\":\"BLOCK\",\"attempt\":1,\"last_diff_sha\":$3,\"prev_diff_sha\":$3}"
}

# The whitespace three are the squash: a newline and a carriage return become a
# space in both readers (the python3 branch separates its fields by newlines, so
# one surviving inside a value would shift every later field down a line), while
# a tab is left alone by both.
fingerprint_shape_case 0 'a fingerprint containing a newline' '"a\nb"'
fingerprint_shape_case 0 'a fingerprint containing a carriage return' '"a\rb"'
fingerprint_shape_case 0 'a fingerprint containing a tab' '"a\tb"'
fingerprint_shape_case 0 'a fingerprint containing unicode' '"지문-✅-트리"'
fingerprint_shape_case 0 'a fingerprint containing an embedded double quote' '"a\"b"'
fingerprint_shape_case 0 'a fingerprint containing an embedded backslash' '"a\\b"'
FP_LONG=$(printf 'a%.0s' {1..4096})
fingerprint_shape_case 0 'a 4096-character fingerprint' "\"$FP_LONG\""
# The last row is the rule's other half: a non-zero number is not a string, so
# it is no fingerprint at all — and the two readers have to agree on that too.
fingerprint_shape_case 2 'a non-zero number being no fingerprint' '3'

rm -rf "$FP_NOJQ"

# One verdict still buys one reaction. Stopping early is a reaction, so an
# abandoned stalled loop has to go quiet after saying it once — the same rule
# that keeps an abandoned BLOCK from blocking every future turn.
PROJ=$(new_proj)
printf '%s\n' "$SAME_FP" > "$PROJ/$STATE_REL"
OUT1=$(abandoned_turn "$PROJ" s1); RC1=$?
OUT2=$(abandoned_turn "$PROJ" a-later-session); RC2=$?
rm -rf "$PROJ"
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] \
   && printf '%s' "$OUT1" | grep -qF '사람 개입' && [ -z "$OUT2" ]; then
  report 0 "$E" "a stalled loop says so once, then goes quiet"
else
  report 1 "$E" "a stalled loop says so once, then goes quiet (rc=$RC1/$RC2 out1='$OUT1' out2='$OUT2')"
fi

# ---------- record-verdict.sh : the diff fingerprint ----------
# A loop can burn its whole budget without moving: the coder re-reads the same
# files, the reviewer re-files the same findings. The fingerprint is what lets
# the next hook see that, so it has to cover everything a coder could have
# changed — a coder that has not committed yet has still moved, and HEAD alone
# would call that cycle stalled.

new_git_proj() {  # -> a fresh temp project dir that is also a git repo with one commit
  local d
  d=$(new_proj)
  git -C "$d" init -q >/dev/null 2>&1
  git -C "$d" config user.email harness@example.invalid
  git -C "$d" config user.name harness-tests
  printf 'one\n' > "$d/tracked.txt"
  git -C "$d" add tracked.txt >/dev/null 2>&1
  git -C "$d" commit -qm init --no-gpg-sign >/dev/null 2>&1
  printf '%s' "$d"
}

record_block() {  # <proj>: one reviewer cycle that files a BLOCK
  assistant_jsonl "$1/block.jsonl" '<verdict>BLOCK</verdict>'
  record_run "$1" "$(subagent_stop_json reviewer "$1/block.jsonl")" >/dev/null
}

PROJ=$(new_git_proj)
record_block "$PROJ"
FP1=$(state_field "$PROJ/$STATE_REL" last_diff_sha)
if [ -n "$FP1" ]; then
  report 0 "$R" "recording in a git repo stores a diff fingerprint"
else
  report 1 "$R" "recording in a git repo stores a diff fingerprint (got '$FP1')"
fi

# Two cycles over an untouched tree have to land on the same fingerprint, and the
# previous one has to survive the write — a value that is only ever overwritten
# can never be compared with anything.
record_block "$PROJ"
FP2=$(state_field "$PROJ/$STATE_REL" last_diff_sha)
PREV2=$(state_field "$PROJ/$STATE_REL" prev_diff_sha)
if [ -n "$FP2" ] && [ "$FP2" = "$FP1" ] && [ "$PREV2" = "$FP1" ]; then
  report 0 "$R" "an unchanged tree fingerprints the same, and the previous value is kept"
else
  report 1 "$R" "an unchanged tree fingerprints the same, and the previous value is kept (last='$FP2' prev='$PREV2' first='$FP1')"
fi

# Uncommitted work is work. This is the case `git rev-parse HEAD` alone gets
# wrong: the coder edited a tracked file and has not committed, so HEAD is
# unchanged and the cycle would read as stalled.
printf 'two\n' > "$PROJ/tracked.txt"
record_block "$PROJ"
FP3=$(state_field "$PROJ/$STATE_REL" last_diff_sha)
PREV3=$(state_field "$PROJ/$STATE_REL" prev_diff_sha)
if [ -n "$FP3" ] && [ "$FP3" != "$FP2" ] && [ "$PREV3" = "$FP2" ]; then
  report 0 "$R" "an uncommitted edit moves the fingerprint (HEAD alone would not)"
else
  report 1 "$R" "an uncommitted edit moves the fingerprint (last='$FP3' prev='$PREV3' before='$FP2')"
fi

# ...and so is a new file nobody has staged, which `git diff HEAD` cannot see
# either. A coder whose whole cycle was "add the test file" has moved.
printf 'brand new\n' > "$PROJ/untracked.txt"
record_block "$PROJ"
FP4=$(state_field "$PROJ/$STATE_REL" last_diff_sha)
if [ -n "$FP4" ] && [ "$FP4" != "$FP3" ]; then
  report 0 "$R" "an untracked new file moves the fingerprint"
else
  report 1 "$R" "an untracked new file moves the fingerprint (last='$FP4' before='$FP3')"
fi

# ...and so is the next edit to that same file. `?? path` is one line whatever
# the file holds, so a fingerprint built out of names alone reads a coder
# iterating on a module it never added as a coder that did nothing — and the
# hook then says the tree is identical when it is not.
printf 'a real second draft\n' > "$PROJ/untracked.txt"
record_block "$PROJ"
FP4B=$(state_field "$PROJ/$STATE_REL" last_diff_sha)
if [ -n "$FP4B" ] && [ "$FP4B" != "$FP4" ]; then
  report 0 "$R" "editing an untracked file moves the fingerprint, not just creating it"
else
  report 1 "$R" "editing an untracked file moves the fingerprint, not just creating it (last='$FP4B' before='$FP4')"
fi

# A commit moves it too, which is the ordinary case: the coder committed its
# green checkpoint between the two reviews.
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" commit -qm work --no-gpg-sign >/dev/null 2>&1
record_block "$PROJ"
FP5=$(state_field "$PROJ/$STATE_REL" last_diff_sha)
if [ -n "$FP5" ] && [ "$FP5" != "$FP4B" ]; then
  report 0 "$R" "committing the same work still moves the fingerprint"
else
  report 1 "$R" "committing the same work still moves the fingerprint (last='$FP5' before='$FP4B')"
fi
rm -rf "$PROJ"

# The hook's own writing does not count as the coder moving. .claude/notes/ is
# where this hook and announce-agent.sh keep their files, and a project that
# does not gitignore that directory would otherwise show a different tree on
# every single cycle — the state file this run is about to write is itself part
# of the difference. No-progress detection would be permanently off, silently.
PROJ=$(new_git_proj)
record_block "$PROJ"
FP1=$(state_field "$PROJ/$STATE_REL" last_diff_sha)
printf 'a later note\n' > "$PROJ/.claude/notes/agent-activity.log"
record_block "$PROJ"
FP2=$(state_field "$PROJ/$STATE_REL" last_diff_sha)
if [ -n "$FP2" ] && [ "$FP2" = "$FP1" ]; then
  report 0 "$R" "the harness's own .claude/notes/ churn does not move the fingerprint"
else
  report 1 "$R" "the harness's own .claude/notes/ churn does not move the fingerprint (last='$FP2' before='$FP1')"
fi

# ...while a sibling under .claude/ does. Untracked entries have to be listed one
# by one for that: git collapses a wholly untracked directory to a single
# `?? .claude/` line, and a second new file inside it would leave the fingerprint
# unchanged — a coder writing hooks or skills would read as stalled.
mkdir -p "$PROJ/.claude/hooks"
printf 'first\n' > "$PROJ/.claude/hooks/one.sh"
record_block "$PROJ"
FP3=$(state_field "$PROJ/$STATE_REL" last_diff_sha)
printf 'second\n' > "$PROJ/.claude/hooks/two.sh"
record_block "$PROJ"
FP4=$(state_field "$PROJ/$STATE_REL" last_diff_sha)
if [ -n "$FP3" ] && [ "$FP3" != "$FP1" ] && [ -n "$FP4" ] && [ "$FP4" != "$FP3" ]; then
  report 0 "$R" "a second new file under .claude/ still moves the fingerprint"
else
  report 1 "$R" "a second new file under .claude/ still moves the fingerprint (one='$FP3' two='$FP4' base='$FP1')"
fi
rm -rf "$PROJ"

# The harness runs wherever the user starts it, and that is not always a git
# repo. No fingerprint is the honest answer there; a crash, or a constant that
# compares equal to itself, would both be worse.
PROJ=$(new_proj)
record_block "$PROJ"
RC=$(record_run "$PROJ" "$(subagent_stop_json reviewer "$PROJ/block.jsonl")")
GOT_FP=$(state_field "$PROJ/$STATE_REL" last_diff_sha)
GOT_V=$(state_field "$PROJ/$STATE_REL" last_verdict)
rm -rf "$PROJ"
if [ "$RC" -eq 0 ] && [ -z "$GOT_FP" ] && [ "$GOT_V" = "BLOCK" ]; then
  report 0 "$R" "outside a git repo -> no fingerprint, the verdict is still recorded, exit 0"
else
  report 1 "$R" "outside a git repo -> no fingerprint, the verdict is still recorded, exit 0 (rc=$RC fp='$GOT_FP' verdict='$GOT_V')"
fi

# ---------- the two hooks : a stalled loop stops before the budget does ----------
# The cases above seed fingerprints by hand. This one lets the hooks produce
# their own, in a real git repo, in the order a session runs them: reviewer
# stop, main turn end, reviewer stop, main turn end. Whether no-progress
# detection works at all is only visible here — a fingerprint the recording
# hook writes and the judging hook cannot compare would pass every case above.

cycle() {  # <proj> -> "<exit-code> <stdout+stderr>" of one reviewer-then-Stop cycle
  local proj="$1" out rc=0
  record_block "$proj"
  out=$(printf '%s' "$(stop_json)" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOKS_DIR/$E" 2>&1) || rc=$?
  printf '%s %s' "$rc" "$out"
}

PROJ=$(new_git_proj)
STALL1=$(cycle "$PROJ")
STALL2=$(cycle "$PROJ")
STALL_ATTEMPT=$(state_field "$PROJ/$STATE_REL" attempt)
rm -rf "$PROJ"
if [ "${STALL1%% *}" -eq 2 ] && printf '%s' "$STALL1" | grep -qF 'attempt 1/3' \
   && [ "${STALL2%% *}" -eq 0 ] && printf '%s' "$STALL2" | grep -qF '무진전' \
   && [ "$STALL_ATTEMPT" = "2" ]; then
  report 0 "loop" "two cycles over an untouched tree: re-dispatch, then stop at 2/3"
else
  report 1 "loop" "two cycles over an untouched tree: re-dispatch, then stop at 2/3 (attempt=$STALL_ATTEMPT '$STALL1' :: '$STALL2')"
fi

# The same two cycles with one edit in between. This is the case that fails if
# the fingerprint is too coarse — an over-eager stop would end a working loop on
# its second attempt, which is worse than not having the feature.
PROJ=$(new_git_proj)
MOVED1=$(cycle "$PROJ")
printf 'the coder did something\n' >> "$PROJ/tracked.txt"
MOVED2=$(cycle "$PROJ")
rm -rf "$PROJ"
if [ "${MOVED1%% *}" -eq 2 ] && [ "${MOVED2%% *}" -eq 2 ] \
   && printf '%s' "$MOVED2" | grep -qF 'attempt 2/3'; then
  report 0 "loop" "one edit between the cycles: the loop keeps its budget and continues"
else
  report 1 "loop" "one edit between the cycles: the loop keeps its budget and continues ('$MOVED1' :: '$MOVED2')"
fi

# The same two cycles again, with the edit landing in a file the coder never
# added — the ordinary shape of a coder rolling a new module before its first
# commit. A fingerprint made of untracked *names* cannot see that, and the hook
# then stops a live loop at 2/3 while saying the tree is identical. Both halves
# are wrong: the stop and the sentence.
PROJ=$(new_git_proj)
printf 'first draft\n' > "$PROJ/newmodule.py"
NEWFILE1=$(cycle "$PROJ")
printf 'a real second draft\n' > "$PROJ/newmodule.py"
NEWFILE2=$(cycle "$PROJ")
rm -rf "$PROJ"
if [ "${NEWFILE1%% *}" -eq 2 ] && [ "${NEWFILE2%% *}" -eq 2 ] \
   && printf '%s' "$NEWFILE2" | grep -qF 'attempt 2/3'; then
  report 0 "loop" "an edit to a never-added file keeps the loop running, not stopped as stalled"
else
  report 1 "loop" "an edit to a never-added file keeps the loop running, not stopped as stalled ('$NEWFILE1' :: '$NEWFILE2')"
fi

# ---------- update.sh : propagation ----------
# The hooks above only matter in this repo until update.sh carries them into the
# projects that use the harness. update.sh clones over the network and copies
# into the current directory, so nothing here runs it end to end: the helper half
# is sourced in isolation and the rest is asserted against the file's text.

UPDATE_SH="$REPO_ROOT/update.sh"

# Sourced from a directory with no .claude/, so that a missing library guard
# stops update.sh at its own sanity check instead of cloning anything.
LIB_SAFE_DIR=$(mktemp -d /tmp/hooktest-lib-XXXXXX)

update_lib() {  # <shell code> -> its stdout, after sourcing update.sh's helper half
  ( cd "$LIB_SAFE_DIR" && HARNESS_UPDATE_LIB=1 . "$UPDATE_SH" && eval "$1" ) 2>/dev/null
}

MANAGED=$(update_lib 'printf "%s" "$MANAGED_HOOKS"')

# Criterion 1 — both loops (diff report, copy) propagate every managed hook.
# record-verdict.sh and enforce-loop.sh were in neither list, so no project
# outside this repo ever received them.
#
# The oracle is the hooks directory, not a list typed here: a seventh hook added
# to disk and forgotten in MANAGED_HOOKS is the exact drift this phase closed,
# and a literal list here would pass right through it a second time.
MISSING_FROM_LIST=""
for F in "$REPO_ROOT"/.claude/hooks/*.sh; do
  # Not about tests/, which is a directory and does not match *.sh at all: this
  # skips a directory that happens to be named something.sh, and the glob itself
  # when the pattern matches nothing.
  [ -f "$F" ] || continue
  H=$(basename "$F" .sh)
  printf '%s' " $MANAGED " | grep -qF " $H " || MISSING_FROM_LIST="$MISSING_FROM_LIST $H"
done
if [ -z "$MISSING_FROM_LIST" ]; then
  report 0 "update.sh" "the managed hook list names every hook the repo ships"
else
  report 1 "update.sh" "the managed hook list names every hook the repo ships (missing:$MISSING_FROM_LIST)"
fi

# Both places that touch an upstream hook file have to sit in the body of a loop
# over that one list — reporting one set of hooks and copying another is how a
# half-fix would look.
LIST_LOOP_BODIES=$(grep -A1 'for h in \$MANAGED_HOOKS; do' "$UPDATE_SH")
if printf '%s' "$LIST_LOOP_BODIES" | grep -qF 'report_diff "$TMP/harness/.claude/hooks/$h.sh"' \
   && printf '%s' "$LIST_LOOP_BODIES" | grep -qF 'cp "$TMP/harness/.claude/hooks/$h.sh"'; then
  report 0 "update.sh" "the diff-report and the copy loop both walk that one list"
else
  report 1 "update.sh" "the diff-report and the copy loop both walk that one list"
fi

# Criterion 2 — one definition, no second copy. What drifts out of sync with
# MANAGED_HOOKS is a second *list*: an assignment or a loop that introduces hook
# names of its own. That is the failure being fixed rather than a style
# preference.
drifting_lists() {  # <file> -> hook names introduced by more than one list
  local file="$1" found="" h n
  # An assignment or a `for ... in` naming the hook. The assignment may be
  # exported, declared or appended to — `+=` in particular reads as adding to the
  # one list while actually writing a second copy of the names. Prose that
  # mentions a hook is left alone: it carries no names into the propagation loops.
  local assign='^[[:space:]]*((local|export|readonly|declare)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)?[A-Za-z_][A-Za-z0-9_]*\+?=[^#]*'
  local loop='^[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]][^#]*'
  for h in $MANAGED; do
    n=$(grep -cE "$assign$h|$loop$h" "$file")
    [ "$n" -eq 1 ] || found="$found $h(x$n)"
  done
  printf '%s' "${found# }"
}

SECOND_COPIES=$(drifting_lists "$UPDATE_SH")
if [ -z "$SECOND_COPIES" ]; then
  report 0 "update.sh" "no hook name is introduced by a second list that could drift"
else
  report 1 "update.sh" "no hook name is introduced by a second list that could drift ($SECOND_COPIES)"
fi

# The check above has to bite on a real second list, in every shape one can be
# written. A plain assignment was the only one it looked for, so a list that
# arrived as an export, an append, or the header of a loop went straight past
# the net that exists to catch exactly that.
second_list_case() {  # <desc> <line to append to a copy of update.sh> <hook> <hook>
  local desc="$1" line="$2" first="$3" second="$4" copy seen
  copy="$LIB_SAFE_DIR/update-second-list-$RANDOM.sh"
  { cat "$UPDATE_SH"; printf '%s\n' "$line"; } > "$copy"
  seen=$(drifting_lists "$copy")
  rm -f "$copy"
  if printf '%s' "$seen" | grep -qF "$first" && printf '%s' "$seen" | grep -qF "$second"; then
    report 0 "update.sh" "$desc"
  else
    report 1 "update.sh" "$desc (got '$seen')"
  fi
}

second_list_case "a second literal list of hooks is caught and named" \
  'LEGACY_HOOKS="block-destructive protect-secrets"' block-destructive protect-secrets
second_list_case "a second list exported instead of assigned is caught too" \
  'export LEGACY_HOOKS="block-destructive protect-secrets"' block-destructive protect-secrets
# `+=` is the shape that drifts most quietly: it reads as adding to the one
# list, and the names it adds are still a second copy of them.
second_list_case "hooks appended to a list with += are caught too" \
  'MANAGED_HOOKS+=" record-verdict enforce-loop"' record-verdict enforce-loop
# The `for` branch has been in the pattern from the start with nothing holding
# it there — a loop naming its own hooks is the second list that skips the
# variable entirely.
second_list_case "a loop that names hooks of its own is caught too" \
  'for legacy in announce-agent post-edit-lint; do :; done' announce-agent post-edit-lint

# ...and stay quiet on a comment. A line that only names a hook cannot drift out
# of sync with anything, and failing the suite for it would read as "propagation
# broke" to whoever hits it — which is not what happened.
COMMENTED_COPY="$LIB_SAFE_DIR/update-with-comment.sh"
{ cat "$UPDATE_SH"; echo '# record-verdict.sh has to run before enforce-loop.sh reads the verdict.'; } > "$COMMENTED_COPY"
COMMENT_DRIFT=$(drifting_lists "$COMMENTED_COPY")
if [ -z "$COMMENT_DRIFT" ]; then
  report 0 "update.sh" "a comment that merely names a hook is not a second list"
else
  report 1 "update.sh" "a comment that merely names a hook is not a second list ($COMMENT_DRIFT)"
fi

# Criterion 5 — "all 4 hooks" was true for years and then quietly was not. Any
# count the user reads has to be derived from the list, so it cannot go stale
# again the next time a hook is added.
TYPED_COUNTS=""
while IFS= read -r PHRASE; do
  [ -n "$PHRASE" ] || continue
  TYPED_COUNTS="$TYPED_COUNTS '$PHRASE'"
done <<< "$(grep -oE '[0-9]+ hooks?' "$UPDATE_SH")"
if [ -z "$TYPED_COUNTS" ] && grep -q 'echo .*\$HOOK_COUNT' "$UPDATE_SH"; then
  report 0 "update.sh" "the hook count the user sees is counted from the list, never typed"
else
  report 1 "update.sh" "the hook count the user sees is counted from the list, never typed (typed:$TYPED_COUNTS)"
fi

# Criterion 3 — a project that already has settings.json keeps it, so the new
# hooks arrive as files nobody runs. Copying them silently is the same as not
# shipping them, except it looks like success, so update.sh has to name them.
LEGACY_SETTINGS="$LIB_SAFE_DIR/legacy-settings.json"
cat > "$LEGACY_SETTINGS" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/block-destructive.sh"}]},
      {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/protect-secrets.sh"}]}
    ],
    "PostToolUse": [
      {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/post-edit-lint.sh"}]}
    ],
    "SubagentStart": [
      {"hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/announce-agent.sh"}]}
    ],
    "SubagentStop": [
      {"hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/announce-agent.sh"}]}
    ]
  }
}
JSON

UNREG=$(update_lib "unregistered_hooks '$LEGACY_SETTINGS'")
if [ "$UNREG" = "record-verdict enforce-loop" ]; then
  report 0 "update.sh" "a pre-loop settings.json leaves exactly the two new hooks unregistered"
else
  report 1 "update.sh" "a pre-loop settings.json leaves exactly the two new hooks unregistered (got '$UNREG')"
fi

NOTICE=$(update_lib "registration_notice '$REPO_ROOT/.claude/settings.json' '$LIB_SAFE_DIR/backup' record-verdict enforce-loop")
if printf '%s' "$NOTICE" | grep -qF 'record-verdict.sh' \
   && printf '%s' "$NOTICE" | grep -qF 'enforce-loop.sh' \
   && printf '%s' "$NOTICE" | grep -qF 'NOT registered'; then
  report 0 "update.sh" "the notice names each unregistered hook and says it is not registered"
else
  report 1 "update.sh" "the notice names each unregistered hook and says it is not registered (got '$NOTICE')"
fi

# The notice only helps if the run reaches it: the summary has to call it
# whenever the kept settings.json is missing a managed hook.
if grep -q 'registration_notice "\$SETTINGS_NEW"' "$UPDATE_SH" \
   && grep -q 'UNREGISTERED_HOOKS=\$(unregistered_hooks' "$UPDATE_SH"; then
  report 0 "update.sh" "the run computes the unregistered hooks and prints the notice"
else
  report 1 "update.sh" "the run computes the unregistered hooks and prints the notice"
fi

# Criterion 4 — naming the hooks is only half an answer; the user still has to
# know what to write. The snippet is lifted out of the shipped settings.json
# rather than typed into update.sh, so it cannot describe a set of hooks that no
# longer exists, and it carries only the missing entries — pasting it must not
# register announce-agent.sh a second time.
SNIPPET=$(update_lib "registration_snippet '$REPO_ROOT/.claude/settings.json' record-verdict enforce-loop")
SNIPPET_SHAPE=$(printf '%s' "$SNIPPET" | python3 -c '
import json, sys

registration = json.load(sys.stdin)
commands = sorted(hook["command"].rsplit("/", 1)[-1]
                  for groups in registration.values()
                  for group in groups
                  for hook in group["hooks"])
print(",".join(sorted(registration)), ",".join(commands))
' 2>/dev/null)
if [ "$SNIPPET_SHAPE" = "Stop,SubagentStop enforce-loop.sh,record-verdict.sh" ]; then
  report 0 "update.sh" "the snippet is valid JSON carrying the Stop and SubagentStop entries, and nothing else"
else
  report 1 "update.sh" "the snippet is valid JSON carrying the Stop and SubagentStop entries, and nothing else (got '$SNIPPET_SHAPE')"
fi

NOTICE=$(update_lib "registration_notice '$REPO_ROOT/.claude/settings.json' '$LIB_SAFE_DIR/backup' record-verdict enforce-loop")
if printf '%s' "$NOTICE" | grep -qF '"Stop"' \
   && printf '%s' "$NOTICE" | grep -qF '"SubagentStop"' \
   && printf '%s' "$NOTICE" | grep -qF '.claude/settings.json'; then
  report 0 "update.sh" "the notice embeds that snippet under the file to paste it into"
else
  report 1 "update.sh" "the notice embeds that snippet under the file to paste it into (got '$NOTICE')"
fi

# python3 prints the snippet, but the notice is the part that must never go
# missing: without a parser it still has to leave the user somewhere to look.
NOTICE_NOPY=$( ( cd "$LIB_SAFE_DIR" \
  && HARNESS_UPDATE_LIB=1 . "$UPDATE_SH" \
  && PATH=/var/empty eval "registration_notice '$REPO_ROOT/.claude/settings.json' '$LIB_SAFE_DIR/backup' record-verdict enforce-loop" ) 2>/dev/null )
if printf '%s' "$NOTICE_NOPY" | grep -qF 'record-verdict.sh' \
   && printf '%s' "$NOTICE_NOPY" | grep -qF 'settings.json.upstream-latest'; then
  report 0 "update.sh" "with no python3 the notice still names the hooks and the file to copy from"
else
  report 1 "update.sh" "with no python3 the notice still names the hooks and the file to copy from (got '$NOTICE_NOPY')"
fi

# An unparseable upstream settings.json is a repo-owned accident and so unlikely,
# but the notice is printed inside the final ✅ Done. block: a python traceback
# between "NOT registered" and the reference path is the worst place a user could
# read one. Only the parser is allowed to fail here, and it has to fail quietly.
BROKEN_UPSTREAM="$LIB_SAFE_DIR/broken-settings.json"
printf '%s\n' '{ "hooks": ' > "$BROKEN_UPSTREAM"
BROKEN_OUT="$LIB_SAFE_DIR/broken-notice.out"
BROKEN_ERR=$( ( cd "$LIB_SAFE_DIR" \
  && HARNESS_UPDATE_LIB=1 . "$UPDATE_SH" \
  && eval "registration_notice '$BROKEN_UPSTREAM' '$LIB_SAFE_DIR/backup' record-verdict enforce-loop" ) \
  2>&1 >"$BROKEN_OUT" )  # stderr to the capture, stdout to the file — order matters
BROKEN_NOTICE=$(cat "$BROKEN_OUT")
if [ -z "$BROKEN_ERR" ] \
   && printf '%s' "$BROKEN_NOTICE" | grep -qF 'record-verdict.sh' \
   && printf '%s' "$BROKEN_NOTICE" | grep -qF 'settings.json.upstream-latest'; then
  report 0 "update.sh" "an unreadable upstream file prints no traceback, just the hooks and the reference"
else
  report 1 "update.sh" "an unreadable upstream file prints no traceback, just the hooks and the reference (stderr '$BROKEN_ERR')"
fi

# Criterion 6 — a project with no settings.json still gets the shipped one, and
# that file has to register every hook the same list propagates. This is the
# other end of the same failure: a hook added to MANAGED_HOOKS but not to
# settings.json would ship into fresh projects already inert.
FRESH_PROJECT_SETTINGS="$LIB_SAFE_DIR/fresh-settings.json"
cp "$REPO_ROOT/.claude/settings.json" "$FRESH_PROJECT_SETTINGS"
FRESH_UNREG=$(update_lib "unregistered_hooks '$FRESH_PROJECT_SETTINGS'")
if [ -z "$FRESH_UNREG" ]; then
  report 0 "update.sh" "the settings.json a fresh project receives registers every propagated hook"
else
  report 1 "update.sh" "the settings.json a fresh project receives registers every propagated hook (inert:$FRESH_UNREG)"
fi

# ...and the run still installs it when the project has none. Nothing may make
# the install conditional on the notice above: the notice is for projects that
# keep their own file.
if grep -q 'if \[ ! -f "\$SETTINGS_USER" \]; then' "$UPDATE_SH" \
   && grep -q 'cp "\$SETTINGS_NEW" "\$SETTINGS_USER"' "$UPDATE_SH"; then
  report 0 "update.sh" "a project with no settings.json still gets the shipped one installed"
else
  report 1 "update.sh" "a project with no settings.json still gets the shipped one installed"
fi

rm -rf "$LIB_SAFE_DIR"

# ---------- summary ----------
TOTAL=$((PASS + FAIL))
echo
echo "==> $PASS/$TOTAL passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
