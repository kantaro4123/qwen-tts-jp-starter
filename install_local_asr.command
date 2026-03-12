#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

if [ ! -d ".venv" ]; then
  echo "先に setup.command を実行してください。"
  exit 1
fi

source .venv/bin/activate
python -m pip install faster-whisper

echo ""
echo "ローカル文字起こし用の faster-whisper を再インストールしました。"
