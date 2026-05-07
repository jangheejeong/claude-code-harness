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
        [--prompt "extra instructions"]

Requires: `claude` CLI v2.1+ on PATH.

Exit codes:
  0  agent finished, see log
  1  bad arguments
  2  claude CLI missing
  3  agent run failed (non-zero exit)
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
    p.add_argument("--dry-run", action="store_true")
    return p.parse_args()


def main() -> int:
    args = parse_args()

    if not shutil.which("claude"):
        print("ERROR: `claude` CLI not on PATH. Install Claude Code v2.1+.",
              file=sys.stderr)
        return 2

    subproj = REPO_ROOT / args.subproject
    if not subproj.is_dir():
        print(f"ERROR: subproject not found: {subproj}", file=sys.stderr)
        return 1

    plans = Path(args.plans_file) if args.plans_file else subproj / "Plans.md"
    if not plans.is_file():
        print(f"ERROR: Plans.md not found at {plans}. Run /plan first.",
              file=sys.stderr)
        return 1

    NOTES_DIR.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    log_path = NOTES_DIR / f"phase-{args.phase}-{args.agent}-{stamp}.log"

    prompt = (
        f"You are operating as the {args.agent} subagent for {args.subproject} "
        f"Phase {args.phase}. The plan is at {plans.relative_to(REPO_ROOT)}. "
        f"Follow your agent definition at .claude/agents/{args.agent}.md "
        f"strictly. Stop at the Phase boundary. {args.prompt}"
    )

    cmd = [
        "claude",
        "--agent", args.agent,
        "--print",                    # non-interactive
        "--output-format", "text",
        prompt,
    ]

    print(f"[run_phase] {args.agent} on Phase {args.phase} of "
          f"{args.subproject}; log -> {log_path.relative_to(REPO_ROOT)}",
          flush=True)

    if args.dry_run:
        print("[run_phase] DRY RUN — would exec:", " ".join(cmd))
        return 0

    with log_path.open("w") as logf:
        proc = subprocess.run(
            cmd,
            cwd=subproj,
            stdout=logf,
            stderr=subprocess.STDOUT,
            text=True,
        )

    status = "OK" if proc.returncode == 0 else f"FAIL({proc.returncode})"
    print(f"[run_phase] status={status} log={log_path.relative_to(REPO_ROOT)}",
          flush=True)
    return 0 if proc.returncode == 0 else 3


if __name__ == "__main__":
    sys.exit(main())
