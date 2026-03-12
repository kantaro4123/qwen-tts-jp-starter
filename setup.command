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

PREFETCH_MODEL="${QWEN_TTS_PREFETCH_MODEL:-1}"
if [ "$PREFETCH_MODEL" = "1" ]; then
  SELECTED_MODEL_ID=$(python - <<'PY'
import json
from pathlib import Path
settings_path = Path("config/settings.json")
if settings_path.exists():
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
        print(settings.get("qwen_tts_model_id", "Qwen/Qwen3-TTS-12Hz-1.7B-Base"))
    except Exception:
        print("Qwen/Qwen3-TTS-12Hz-1.7B-Base")
else:
    print("Qwen/Qwen3-TTS-12Hz-1.7B-Base")
PY
)
  echo ""
  echo "選択された Qwen-TTS モデルを事前ダウンロードします: $SELECTED_MODEL_ID"
  python - <<PY
import torch
from qwen_tts import Qwen3TTSModel
Qwen3TTSModel.from_pretrained(
    "$SELECTED_MODEL_ID",
    device_map="cpu",
    dtype=torch.float32,
    attn_implementation="eager",
)
print("prefetch complete")
PY
fi

echo ""
echo "セットアップが完了しました。"
echo "使用した Python: $PYTHON_BIN"
echo "次は run.command を実行してください。"
