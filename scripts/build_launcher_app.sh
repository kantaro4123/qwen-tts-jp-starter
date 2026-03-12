#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_DIR="$PROJECT_DIR/build/macos-launcher"
APP_NAME="かんたんボイスクローン.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
APP_EXECUTABLE_NAME="kantan-voice-clone"
APP_SOURCE="$PROJECT_DIR/macos/DesktopApp.swift"
SWIFT_MODULE_CACHE_DIR="$PROJECT_DIR/build/.swift-module-cache"
PAYLOAD_DIR="$BUILD_DIR/standalone-payload"
PAYLOAD_RUNTIME_DIR="$PAYLOAD_DIR/runtime"
MODEL_BUNDLE_DIR="$BUILD_DIR/model-bundle"
APP_VERSION_RAW=$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || echo "0.3.0")
APP_VERSION="${APP_VERSION_RAW#v}"
CODESIGN_IDENTITY="${MACOS_CODESIGN_IDENTITY:--}"
BUNDLE_QWEN_MODEL_ID="${BUNDLE_QWEN_MODEL_ID:-}"
BUNDLE_QWEN_MODEL_SOURCE_DIR="${BUNDLE_QWEN_MODEL_SOURCE_DIR:-}"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$PAYLOAD_RUNTIME_DIR" "$SWIFT_MODULE_CACHE_DIR"

if [ ! -x "$PROJECT_DIR/.venv/bin/python" ]; then
  echo "standalone アプリをビルドするには、先に ./setup.command で .venv を作成してください。" >&2
  exit 1
fi

rsync -a \
  --exclude ".git" \
  --exclude "build" \
  --exclude "dist" \
  --exclude "outputs" \
  --exclude ".gradio" \
  --exclude "__pycache__" \
  --exclude ".DS_Store" \
  "$PROJECT_DIR/" "$PAYLOAD_RUNTIME_DIR/"

python3 "$PROJECT_DIR/scripts/prune_standalone_runtime.py" "$PAYLOAD_RUNTIME_DIR"

if [ -n "$BUNDLE_QWEN_MODEL_ID" ] || [ -n "$BUNDLE_QWEN_MODEL_SOURCE_DIR" ]; then
  mkdir -p "$MODEL_BUNDLE_DIR"
  PYTHON_FOR_BUNDLE="$PROJECT_DIR/.venv/bin/python"
  if [ ! -x "$PYTHON_FOR_BUNDLE" ]; then
    PYTHON_FOR_BUNDLE="python3"
  fi
  model_id="${BUNDLE_QWEN_MODEL_ID:-Qwen/Qwen3-TTS-12Hz-1.7B-Base}"
  bundle_args=(
    "$PYTHON_FOR_BUNDLE"
    "$PROJECT_DIR/scripts/prepare_bundled_model.py"
    --model-id "$model_id"
    --output-dir "$MODEL_BUNDLE_DIR"
  )
  if [ -n "$BUNDLE_QWEN_MODEL_SOURCE_DIR" ]; then
    bundle_args+=(--source-dir "$BUNDLE_QWEN_MODEL_SOURCE_DIR")
  fi
  "${bundle_args[@]}"
  COPYFILE_DISABLE=1 /usr/bin/tar -czf "$APP_DIR/Contents/Resources/bundled-models.tar.gz" -C "$MODEL_BUNDLE_DIR" .
  cp "$MODEL_BUNDLE_DIR/model-map.json" "$APP_DIR/Contents/Resources/bundled-model-map.json"
fi

swiftc \
  -O \
  -module-cache-path "$SWIFT_MODULE_CACHE_DIR" \
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

COPYFILE_DISABLE=1 /usr/bin/tar -czf "$APP_DIR/Contents/Resources/runtime.tar.gz" -C "$PAYLOAD_DIR" runtime
cp "$PROJECT_DIR/README.md" "$APP_DIR/Contents/Resources/README.md"
printf '%s\n' "$APP_VERSION" > "$APP_DIR/Contents/Resources/runtime-version.txt"

chmod +x "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR" >/dev/null 2>&1 || true

echo "Built standalone desktop app:"
echo "$APP_DIR"
