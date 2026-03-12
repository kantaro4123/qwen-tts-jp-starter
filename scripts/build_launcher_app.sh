#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_DIR="$PROJECT_DIR/build/macos-launcher"
APP_NAME="かんたんボイスクローン.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
APP_SCRIPT="$PROJECT_DIR/macos/launcher.applescript"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

osacompile -o "$APP_DIR" "$APP_SCRIPT"

mkdir -p "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/macos/launcher.sh" "$APP_DIR/Contents/Resources/launcher.sh"
chmod +x "$APP_DIR/Contents/Resources/launcher.sh"

plutil -replace CFBundleDisplayName -string "かんたんボイスクローン" "$APP_DIR/Contents/Info.plist"
plutil -replace CFBundleName -string "かんたんボイスクローン" "$APP_DIR/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.kantaro.qwenttsjpstarter" "$APP_DIR/Contents/Info.plist"

echo "Built launcher app:"
echo "$APP_DIR"
