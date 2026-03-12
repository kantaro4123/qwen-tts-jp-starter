# DMG 化の進め方

## 今の方針

まずは「ランチャー型 `.app`」を作り、その `.app` を含む配布フォルダを `.dmg` にまとめます。  
これは Python や `torch` を完全同梱するより現実的で、初心者向けの導線を早く作れます。

## 作るもの

- `かんたんボイスクローン.app`
- 配布用 `.dmg`

## ビルド手順

### ランチャー `.app` を作る

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

- この段階では完全単体アプリではありません
- 初回起動時は内部で `setup.command` が走ります
- 起動にはターミナル画面が開きますが、手入力は不要です

## 次の改善候補

- `Gatekeeper` 向けの署名と公証
- 進捗を GUI で見せるネイティブランチャー
- Python / 依存関係ごと同梱した単体 `.app`
