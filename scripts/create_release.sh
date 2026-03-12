#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

if [ $# -lt 1 ]; then
  echo "使い方: ./scripts/create_release.sh v0.1.0 [notes-file]"
  exit 1
fi

VERSION="$1"
NOTES_FILE="${2:-$PROJECT_DIR/docs/releases/$VERSION.md}"
DMG_PATH="$PROJECT_DIR/dist/qwen-tts-jp-starter-macos.dmg"
ZIP_PATH="$PROJECT_DIR/dist/qwen-tts-jp-starter-macos-app.zip"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI が見つかりませんでした。GitHub Release の作成には gh が必要です。"
  exit 1
fi

cd "$PROJECT_DIR"

"$SCRIPT_DIR/build_dmg.sh"
"$SCRIPT_DIR/build_zip.sh"

if [ ! -f "$NOTES_FILE" ]; then
  echo "リリースノートが見つかりません: $NOTES_FILE"
  exit 1
fi

if gh release view "$VERSION" >/dev/null 2>&1; then
  gh release upload "$VERSION" "$DMG_PATH" "$ZIP_PATH" --clobber
  gh release edit "$VERSION" --title "$VERSION" --notes-file "$NOTES_FILE"
else
  gh release create "$VERSION" "$DMG_PATH" "$ZIP_PATH" --title "$VERSION" --notes-file "$NOTES_FILE"
fi

echo "GitHub Release を更新しました: $VERSION"
