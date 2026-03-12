#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_DIR="$PROJECT_DIR/build/macos-launcher"
APP_NAME="かんたんボイスクローン.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
APP_EXECUTABLE_NAME="kantan-voice-clone"
APP_SOURCE="$PROJECT_DIR/macos/DesktopApp.swift"
PAYLOAD_DIR="$BUILD_DIR/standalone-payload"
PAYLOAD_RUNTIME_DIR="$PAYLOAD_DIR/runtime"
APP_VERSION=$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || echo "0.2.0")

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$PAYLOAD_RUNTIME_DIR"

rsync -a \
  --exclude ".git" \
  --exclude "build" \
  --exclude "dist" \
  --exclude "outputs" \
  --exclude ".gradio" \
  --exclude "__pycache__" \
  --exclude ".DS_Store" \
  "$PROJECT_DIR/" "$PAYLOAD_RUNTIME_DIR/"

python3 - <<PY
from pathlib import Path
import shutil

root = Path(r"$PAYLOAD_RUNTIME_DIR")
for path in list(root.rglob("__pycache__")):
    shutil.rmtree(path, ignore_errors=True)
for path in list(root.rglob("*.pyc")):
    path.unlink(missing_ok=True)
PY

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
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

COPYFILE_DISABLE=1 tar -czf "$APP_DIR/Contents/Resources/runtime.tar.gz" -C "$PAYLOAD_DIR" runtime
cp "$PROJECT_DIR/README.md" "$APP_DIR/Contents/Resources/README.md"
printf '%s\n' "$APP_VERSION" > "$APP_DIR/Contents/Resources/runtime-version.txt"

chmod +x "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built standalone desktop app:"
echo "$APP_DIR"
