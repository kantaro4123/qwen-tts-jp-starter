#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

if [ -x .venv/bin/python ]; then
  exec .venv/bin/python scripts/doctor.py
fi

exec python3 scripts/doctor.py
