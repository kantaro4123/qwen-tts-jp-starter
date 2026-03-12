#!/bin/zsh
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "使い方: ./scripts/sign_macos_app.sh /path/to/app-or-dmg"
  exit 1
fi

TARGET="$1"
IDENTITY="${MACOS_CODESIGN_IDENTITY:-}"

if [ -z "$IDENTITY" ]; then
  echo "MACOS_CODESIGN_IDENTITY が未設定です。"
  exit 1
fi

codesign --force --deep --options runtime --sign "$IDENTITY" "$TARGET"
codesign --verify --deep --strict "$TARGET"
spctl --assess --type exec "$TARGET" || true

echo "Signed: $TARGET"
