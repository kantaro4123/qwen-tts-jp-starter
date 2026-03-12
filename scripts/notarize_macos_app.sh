#!/bin/zsh
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "使い方: ./scripts/notarize_macos_app.sh /path/to/dmg-or-zip"
  exit 1
fi

TARGET="$1"
PROFILE="${MACOS_NOTARY_PROFILE:-}"
TEAM_ID="${MACOS_TEAM_ID:-}"
APPLE_ID="${MACOS_APPLE_ID:-}"
APPLE_PASSWORD="${MACOS_APP_SPECIFIC_PASSWORD:-}"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun が見つかりません。Xcode Command Line Tools を確認してください。"
  exit 1
fi

if [ -n "$PROFILE" ]; then
  xcrun notarytool submit "$TARGET" --keychain-profile "$PROFILE" --wait
else
  if [ -z "$TEAM_ID" ] || [ -z "$APPLE_ID" ] || [ -z "$APPLE_PASSWORD" ]; then
    echo "MACOS_NOTARY_PROFILE か、MACOS_TEAM_ID / MACOS_APPLE_ID / MACOS_APP_SPECIFIC_PASSWORD を設定してください。"
    exit 1
  fi
  xcrun notarytool submit "$TARGET" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APPLE_PASSWORD" \
    --wait
fi

xcrun stapler staple "$TARGET" || true

echo "Notarized: $TARGET"
