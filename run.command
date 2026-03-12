#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

if [ ! -d ".venv" ]; then
  echo "まだセットアップされていません。先に setup.command を実行してください。"
  exit 1
fi

source .venv/bin/activate
export QWEN_TTS_PORT="${QWEN_TTS_PORT:-7860}"

if [ "${QWEN_TTS_NO_OPEN_BROWSER:-0}" != "1" ]; then
  (
    sleep 2
    open "http://127.0.0.1:${QWEN_TTS_PORT}"
  ) &
fi

python app.py
