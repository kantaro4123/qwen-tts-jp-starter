#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

pick_python() {
  for candidate in python3.12 python3.11 python3.10 python3.9 python3; do
    if ! command -v "$candidate" >/dev/null 2>&1; then
      continue
    fi

    if "$candidate" - <<'PY' >/dev/null 2>&1
import sys
sys.exit(0 if sys.version_info >= (3, 9) else 1)
PY
    then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

PYTHON_BIN=$(pick_python || true)

if [ -z "$PYTHON_BIN" ]; then
  echo "Python 3.9 以上が見つかりませんでした。先に Python をインストールしてから再実行してください。"
  exit 1
fi

"$PYTHON_BIN" -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip setuptools wheel
python -m pip install -r requirements.txt

echo ""
echo "セットアップが完了しました。"
echo "使用した Python: $PYTHON_BIN"
echo "次は run.command を実行してください。"
