#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_DIR="$PROJECT_DIR/build/macos-launcher"
APP_NAME="かんたんボイスクローン.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
APP_EXECUTABLE_NAME="kantan-voice-clone"
APP_SOURCE="$PROJECT_DIR/macos/DesktopApp.swift"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc \
  -O \
  -framework AppKit \
  -framework WebKit \
  "$APP_SOURCE" \
  -o "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ja</string>
  <key>CFBundleDisplayName</key>
  <string>かんたんボイスクローン</string>
  <key>CFBundleExecutable</key>
  <string>$APP_EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.kantaro.qwenttsjpstarter</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>かんたんボイスクローン</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built desktop app:"
echo "$APP_DIR"
