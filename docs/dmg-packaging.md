# DMG 化の進め方

## 今の方針

まずは「WebView でアプリ内表示しつつ、Python 実行環境も同梱した standalone `.app`」を作り、その `.app` を `.dmg` にまとめます。  
これで初心者向けの導線をかなり簡単にできます。

## 作るもの

- `かんたんボイスクローン.app`
- 配布用 `.dmg`
- `.app` 内の `runtime.tar.gz` と `README.md`
- 必要に応じて `.app` 内の `bundled-models.tar.gz`

## ビルド手順

### `.app` を作る

```bash
./scripts/build_launcher_app.sh
```

### `.dmg` を作る

```bash
./scripts/build_dmg.sh
```

## できあがる場所

- `.app`: `build/macos-launcher/かんたんボイスクローン.app`
- `.dmg`: `dist/qwen-tts-jp-starter-macos.dmg`

## 今の制約

- Python や主要ライブラリは同梱していますが、モデル本体までは同梱していません
- 初回の音声生成時は、モデルのダウンロードやキャッシュ準備で時間がかかることがあります
- UI はブラウザではなく `.app` の中に表示します

モデルを同梱したビルドを作りたい場合は、[signing-notarization.md](signing-notarization.md) の `モデル同梱つきビルド` を使ってください。

## 次の改善候補

- `Gatekeeper` 向けの署名と公証
- セットアップ進捗をもう少し分かりやすく見せる
- モデル本体まで含めた完全オフライン配布
