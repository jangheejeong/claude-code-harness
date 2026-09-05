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

# A reviewer may quote the tag inside its findings; only the closing one counts.
verdict_case 5 "BLOCK" "multiple tags -> last one wins" \
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

# ---------- summary ----------
TOTAL=$((PASS + FAIL))
echo
echo "==> $PASS/$TOTAL passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
