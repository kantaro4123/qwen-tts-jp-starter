#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_DIR="$PROJECT_DIR/build"
STAGE_DIR="$BUILD_DIR/dmg-stage"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="かんたんボイスクローン.app"
DMG_NAME="qwen-tts-jp-starter-macos.dmg"
WELCOME_FILE="$PROJECT_DIR/macos/はじめに.txt"

"$SCRIPT_DIR/build_launcher_app.sh"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

cp -R "$BUILD_DIR/macos-launcher/$APP_NAME" "$STAGE_DIR/$APP_NAME"
cp "$WELCOME_FILE" "$STAGE_DIR/はじめに.txt"
ln -s /Applications "$STAGE_DIR/Applications"

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$DMG_NAME"

hdiutil create \
  -volname "かんたんボイスクローン" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DIST_DIR/$DMG_NAME"

echo "Built dmg:"
echo "$DIST_DIR/$DMG_NAME"
