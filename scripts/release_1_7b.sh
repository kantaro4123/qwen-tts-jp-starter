#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

if [ $# -lt 1 ]; then
  echo "使い方: ./scripts/release_1_7b.sh v0.5.0 [notes-file]"
  exit 1
fi

VERSION="$1"
NOTES_FILE="${2:-$PROJECT_DIR/docs/releases/$VERSION.md}"

export BUNDLE_QWEN_MODEL_ID="${BUNDLE_QWEN_MODEL_ID:-Qwen/Qwen3-TTS-12Hz-1.7B-Base}"

echo "標準の 1.7B モデル同梱版を Release として作成します。"
echo "モデル: $BUNDLE_QWEN_MODEL_ID"

"$SCRIPT_DIR/create_release.sh" "$VERSION" "$NOTES_FILE"
