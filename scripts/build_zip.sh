#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="かんたんボイスクローン.app"
ZIP_NAME="qwen-tts-jp-starter-macos-app.zip"
APP_PATH="$BUILD_DIR/macos-launcher/$APP_NAME"

"$SCRIPT_DIR/build_launcher_app.sh"

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$ZIP_NAME"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$DIST_DIR/$ZIP_NAME"

echo "Built zip:"
echo "$DIST_DIR/$ZIP_NAME"
