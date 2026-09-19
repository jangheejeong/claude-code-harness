#!/bin/bash
set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
BLOCK="$ROOT/.claude/hooks/block-destructive.sh"
SECRETS="$ROOT/.claude/hooks/protect-secrets.sh"
passed=0
failed=0

check() {
  local name="$1" expected="$2" script="$3" payload="$4" actual
  set +e
  printf '%s' "$payload" | bash "$script" >/dev/null 2>/dev/null
  actual=$?
  set -e
  if [ "$actual" -eq "$expected" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL %s: expected %s, got %s\n' "$name" "$expected" "$actual" >&2
  fi
}

set -e

check "root rm" 2 "$BLOCK" '{"tool_input":{"command":"rm -rf /"}}'
check "home rm" 2 "$BLOCK" '{"tool_input":{"command":"rm -rf $HOME"}}'
check "system rm in compound command" 2 "$BLOCK" '{"tool_input":{"command":"echo ok && rm -rf /etc/cache"}}'
check "force push" 2 "$BLOCK" '{"tool_input":{"command":"git push --force origin main"}}'
check "short force push" 2 "$BLOCK" '{"tool_input":{"command":"git -C repo push -f origin main"}}'
check "force refspec" 2 "$BLOCK" '{"tool_input":{"command":"git push origin +main"}}'
check "remote hard reset" 2 "$BLOCK" '{"tool_input":{"command":"git reset --hard origin/main"}}'
check "physical disk write" 2 "$BLOCK" '{"tool_input":{"command":"dd if=/tmp/x of=/dev/rdisk2"}}'
check "build cleanup" 0 "$BLOCK" '{"tool_input":{"command":"rm -rf build"}}'
check "normal push" 0 "$BLOCK" '{"tool_input":{"command":"git push origin feature/x"}}'
check "local hard reset" 0 "$BLOCK" '{"tool_input":{"command":"git reset --hard HEAD~1"}}'
check "invalid input fails open" 0 "$BLOCK" 'not-json'

check "env file" 2 "$SECRETS" '{"tool_input":{"file_path":"/tmp/.env.local"}}'
check "private key" 2 "$SECRETS" '{"tool_input":{"file_path":"/tmp/client.pem"}}'
check "credential json" 2 "$SECRETS" '{"tool_input":{"file_path":"/tmp/aws-credentials.json"}}'
check "mcp config" 2 "$SECRETS" '{"tool_input":{"file_path":"/tmp/.mcp.json"}}'
check "env template" 0 "$SECRETS" '{"tool_input":{"file_path":"/tmp/.env.example"}}'
check "credential docs" 0 "$SECRETS" '{"tool_input":{"file_path":"/tmp/credentials.md"}}'
check "source token name" 0 "$SECRETS" '{"tool_input":{"file_path":"/tmp/token_service.py"}}'
check "ordinary source" 0 "$SECRETS" '{"tool_input":{"file_path":"/tmp/service.py"}}'

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
