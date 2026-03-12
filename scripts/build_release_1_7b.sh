#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

export BUNDLE_QWEN_MODEL_ID="${BUNDLE_QWEN_MODEL_ID:-Qwen/Qwen3-TTS-12Hz-1.7B-Base}"

echo "標準の 1.7B モデル同梱版をビルドします。"
echo "モデル: $BUNDLE_QWEN_MODEL_ID"

"$SCRIPT_DIR/build_zip.sh"
"$SCRIPT_DIR/build_dmg.sh"

echo ""
echo "完了:"
echo "$PROJECT_DIR/dist/qwen-tts-jp-starter-macos-app.zip"
echo "$PROJECT_DIR/dist/qwen-tts-jp-starter-macos.dmg"
