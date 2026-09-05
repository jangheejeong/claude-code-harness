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

INPUT=$(cat 2>/dev/null) || INPUT=""

# Stop fires at the end of every main turn, ordinary conversation included.
# No state file means no review loop is in flight, so leave before judging
# anything — a leak here would trap plain chat in a hook it never asked for.
[ -f "$STATE_FILE" ] || exit 0

exit 0
