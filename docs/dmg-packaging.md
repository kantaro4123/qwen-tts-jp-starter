# ZIP / DMG 配布の進め方

## 今の方針

まずは「WebView でアプリ内表示しつつ、Python 実行環境も同梱した standalone `.app`」を作ります。  
配布の主役は `.zip`、`.dmg` は補助です。これで Gatekeeper の確認を 1 回に寄せやすくします。

## 作るもの

- `かんたんボイスクローン.app`
- 配布用 `.zip`
- 必要に応じて配布用 `.dmg`
- `.app` 内の `runtime.tar.gz` と `README.md`
- 必要に応じて `.app` 内の `bundled-models.tar.gz`

## ビルド手順

### `.app` を作る

```bash
./scripts/build_launcher_app.sh
```

### `.zip` を作る

```bash
./scripts/build_zip.sh
```

### `.dmg` を作る

```bash
./scripts/build_dmg.sh
```

標準の `1.7B` 同梱版を配るなら、次のプリセットが最短です。

```bash
./scripts/build_release_1_7b.sh
```

## できあがる場所

- `.app`: `build/macos-launcher/かんたんボイスクローン.app`
- `.zip`: `dist/qwen-tts-jp-starter-macos-app.zip`
- `.dmg`: `dist/qwen-tts-jp-starter-macos.dmg`

## 今の制約

- Python や主要ライブラリは同梱していますが、モデル本体までは同梱していません
- 初回の音声生成時は、モデルのダウンロードやキャッシュ準備で時間がかかることがあります
- UI はブラウザではなく `.app` の中に表示します
- 未署名・未公証の配布では、初回起動時に Gatekeeper の確認が出ることがあります

モデルを同梱したビルドを作りたい場合は、[signing-notarization.md](signing-notarization.md) の `モデル同梱つきビルド` を使ってください。
