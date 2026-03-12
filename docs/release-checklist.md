# Release Checklist

初心者向けの DMG を公開するときの最小チェックです。

## 標準方針

- 標準モデルは `Qwen/Qwen3-TTS-12Hz-1.7B-Base`
- Apple Developer 未加入でも配布可能
- 初回起動時の警告は README と `はじめに.txt` で案内する

## 事前確認

1. `README.md` の冒頭リンクが最新 Release 直リンクになっている
2. `docs/releases/<version>.md` を作成済み
3. `はじめに.txt` の案内が最新の配布手順に合っている
4. 先に `./setup.command` を実行して `.venv` を作成済み
5. `swiftc -typecheck` が通る
6. `zsh -n` と `py_compile` が通る

## 標準の 1.7B 同梱版を作る

```bash
./scripts/build_release_1_7b.sh
```

## GitHub Release を作る

```bash
git tag -f v0.x.y
git push origin v0.x.y --force
./scripts/release_1_7b.sh v0.x.y docs/releases/v0.x.y.md
```

## Apple Developer がない場合

- 署名なし / 公証なしのままで公開してよい
- その代わり、初回起動時に `右クリック > 開く` が必要になることがある
- その案内を README と `はじめに.txt` に残しておく

## Apple Developer がある場合

```bash
export MACOS_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./scripts/sign_macos_app.sh build/macos-launcher/かんたんボイスクローン.app
./scripts/sign_macos_app.sh dist/qwen-tts-jp-starter-macos.dmg
```

必要なら続けて公証:

```bash
export MACOS_NOTARY_PROFILE="your-notary-profile"
./scripts/notarize_macos_app.sh dist/qwen-tts-jp-starter-macos.dmg
```
