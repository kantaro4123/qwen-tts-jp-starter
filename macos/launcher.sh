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
  osascript -e 'display dialog "初回セットアップを始めます。数分かかることがあります。" buttons {"OK"} default button "OK"' || true
  echo "初回セットアップを始めます..."
  ./setup.command
  osascript -e 'display notification "初回セットアップが終わりました。" with title "かんたんボイスクローン"' || true
fi

osascript -e 'display notification "アプリを起動します。ブラウザが開くまで少し待ってください。" with title "かんたんボイスクローン"' || true
./run.command
