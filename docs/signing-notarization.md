# macOS 署名と公証

## 目的

配布する `.app` / `.dmg` を Gatekeeper で扱いやすくするための手順です。

## 前提

- Apple Developer Program のアカウント
- `Developer ID Application` の署名用証明書
- `xcrun notarytool` が使える環境

## 署名

```bash
export MACOS_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./scripts/sign_macos_app.sh build/macos-launcher/かんたんボイスクローン.app
./scripts/sign_macos_app.sh dist/qwen-tts-jp-starter-macos.dmg
```

## 公証

### Keychain Profile を使う場合

```bash
export MACOS_NOTARY_PROFILE="your-notary-profile"
./scripts/notarize_macos_app.sh dist/qwen-tts-jp-starter-macos.dmg
```

### Apple ID を使う場合

```bash
export MACOS_TEAM_ID="TEAMID"
export MACOS_APPLE_ID="your-apple-id@example.com"
export MACOS_APP_SPECIFIC_PASSWORD="app-specific-password"
./scripts/notarize_macos_app.sh dist/qwen-tts-jp-starter-macos.dmg
```

## モデル同梱つきビルド

### すでにローカルにモデルがある場合

```bash
export BUNDLE_QWEN_MODEL_ID="Qwen/Qwen3-TTS-12Hz-1.7B-Base"
export BUNDLE_QWEN_MODEL_SOURCE_DIR="/absolute/path/to/local/model"
./scripts/build_dmg.sh
```

### Hugging Face から取得しながら同梱する場合

```bash
export BUNDLE_QWEN_MODEL_ID="Qwen/Qwen3-TTS-12Hz-1.7B-Base"
./scripts/build_dmg.sh
```

この場合、`.app` 内にモデルバンドルが入り、初回セットアップ時に展開されます。
