#!/usr/bin/env python3
"""run_phase.py — invoke a Claude Code subagent for one Phase, log its output.

Designed to be called from within a Claude Code session by the /orchestrator
skill, *not* as a standalone CLI replacement for `claude`. The point is to
keep verbose subagent output out of the main context window: this script
captures stdout to a log file and prints a single-line status to stdout.

Usage:
    python scripts/harness/run_phase.py \
        --subproject api-server \
        --phase 2 \
        --agent coder \
        [--plans-file <subproject>/Plans.md] \
        [--prompt "extra instructions"] \
        [--timeout 3600] \
        [--permission-mode acceptEdits] \
        [--allowed-tools "Bash Edit Read"]

Requires: `claude` CLI v2.1+ on PATH.

Exit codes:
  0  agent finished, see log
  1  bad arguments
  2  claude CLI missing
  3  agent run failed (non-zero exit or timeout)
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
NOTES_DIR = REPO_ROOT / ".claude" / "notes"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--subproject", required=True,
                   help="Top-level subproject dir, e.g. api-server")
    p.add_argument("--phase", required=True, type=int)
    p.add_argument("--agent", required=True,
                   choices=["explorer", "planner", "coder", "tester",
                            "reviewer", "documenter"])
    p.add_argument("--plans-file", default=None,
                   help="Default: <subproject>/Plans.md")
    p.add_argument("--prompt", default="",
                   help="Additional instructions appended to the agent prompt")
    p.add_argument("--timeout", type=int, default=3600,
                   help="Kill the agent run after N seconds (default: 3600)")
    p.add_argument("--permission-mode", default="acceptEdits",
                   help="Passed through to `claude --permission-mode` "
                        "(default: acceptEdits — --print cannot answer prompts; "
                        "the PreToolUse safety hooks remain the guardrail)")
    p.add_argument("--allowed-tools", default=None,
                   help="Passed through to `claude --allowedTools`, "
                        "e.g. 'Bash Edit Read'")
    p.add_argument("--dry-run", action="store_true")
    return p.parse_args()


def main() -> int:
    args = parse_args()

    if not shutil.which("claude"):
        print("ERROR: `claude` CLI not on PATH. Install Claude Code v2.1+.",
              file=sys.stderr)
        return 2

    # Resolve everything to absolute paths up front: the prompt is consumed by a
    # subprocess running with cwd=<subproject>, and relative args would otherwise
    # break (or crash relative_to) depending on the caller's cwd.
    subproj = Path(args.subproject)
    if not subproj.is_absolute():
        subproj = REPO_ROOT / subproj
    subproj = subproj.resolve()
    if not subproj.is_dir():
        print(f"ERROR: subproject not found: {subproj}", file=sys.stderr)
        return 1

    plans = (Path(args.plans_file).resolve() if args.plans_file
             else subproj / "Plans.md")
    if not plans.is_file():
        print(f"ERROR: Plans.md not found at {plans}. Run /plan first.",
              file=sys.stderr)
        return 1

    NOTES_DIR.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    log_path = NOTES_DIR / f"phase-{args.phase}-{args.agent}-{stamp}.log"

    # Absolute paths only — the prompt must stay valid from the subprocess cwd.
    agent_def = REPO_ROOT / ".claude" / "agents" / f"{args.agent}.md"
    prompt = (
        f"You are operating as the {args.agent} subagent for {args.subproject} "
        f"Phase {args.phase}. The plan is at {plans}. "
        f"Follow your agent definition at {agent_def} "
        f"strictly. Stop at the Phase boundary. {args.prompt}"
    )

    cmd = [
        "claude",
        "--agent", args.agent,
        "--print",                    # non-interactive
        "--output-format", "text",
        # --print cannot answer permission prompts; acceptEdits (default) lets the
        # agent write files while the PreToolUse hooks still guard destructive ops.
        "--permission-mode", args.permission_mode,
    ]
    if args.allowed_tools:
        cmd += ["--allowedTools", args.allowed_tools]
    cmd.append(prompt)

    print(f"[run_phase] {args.agent} on Phase {args.phase} of "
          f"{args.subproject}; log -> {log_path.relative_to(REPO_ROOT)}",
          flush=True)

    if args.dry_run:
        print("[run_phase] DRY RUN — would exec:", " ".join(cmd))
        return 0

    with log_path.open("w") as logf:
        try:
            proc = subprocess.run(
                cmd,
                cwd=subproj,
                stdout=logf,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=args.timeout,
            )
        except subprocess.TimeoutExpired:
            print(f"[run_phase] status=FAIL(timeout after {args.timeout}s) "
                  f"log={log_path.relative_to(REPO_ROOT)}", flush=True)
            return 3

    status = "OK" if proc.returncode == 0 else f"FAIL({proc.returncode})"
    print(f"[run_phase] status={status} log={log_path.relative_to(REPO_ROOT)}",
          flush=True)
    return 0 if proc.returncode == 0 else 3


if __name__ == "__main__":
    sys.exit(main())
