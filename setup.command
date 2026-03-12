#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

if ! command -v python3.12 >/dev/null 2>&1; then
  echo "python3.12 が見つかりませんでした。Homebrew などで Python 3.12 を入れてから再実行してください。"
  exit 1
fi

python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip setuptools wheel
python -m pip install -r requirements.txt

echo ""
echo "セットアップが完了しました。"
echo "次は run.command を実行してください。"
