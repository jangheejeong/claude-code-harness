#!/bin/bash
# Backward-compatible entry point. The canonical installer is scripts/install.py.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
exec python3 "$ROOT/scripts/install.py" "$@"
