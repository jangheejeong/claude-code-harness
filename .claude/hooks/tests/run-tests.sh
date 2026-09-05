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

# The reviewer may quote a tag while deliberating; only its final answer counts.
# Reading thinking blocks would let a rehearsed APPROVE reset the budget.
PROJ=$(new_proj)
{
  printf '{"type":"assistant","message":{"content":['
  printf '{"type":"thinking","thinking":"<verdict>APPROVE</verdict> 로 끝낼까 했지만"},'
  printf '{"type":"text","text":"### 결론\\nBLOCK\\n\\n<verdict>BLOCK</verdict>"}'
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
survives_case "reviewer with a transcript path that does not exist -> exit 0" \
  "$(subagent_stop_json reviewer /nonexistent/transcript.jsonl)"

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

# ---------- summary ----------
TOTAL=$((PASS + FAIL))
echo
echo "==> $PASS/$TOTAL passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
