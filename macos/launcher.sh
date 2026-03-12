#!/bin/zsh
set -euo pipefail

APP_DIR=$(cd "$(dirname "$0")/../.." && pwd)
PROJECT_DIR=$(cd "$APP_DIR/.." && pwd)

if [ ! -f "$PROJECT_DIR/run.command" ]; then
  osascript -e 'display alert "起動に失敗しました" message "run.command が見つかりませんでした。配布フォルダの中身を動かしているか確認してください。"' || true
  exit 1
fi

cd "$PROJECT_DIR"

if [ ! -d ".venv" ]; then
  echo "初回セットアップを始めます..."
  ./setup.command
fi

./run.command
