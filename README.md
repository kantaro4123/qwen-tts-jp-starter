# qwen-tts-jp-starter

`Qwen-TTS` を、日本語でわかりやすく始めるための初心者向けスターターです。  
Apple Silicon の Mac で、できるだけ迷わずボイスクローンを試せることを目的にしています。

**最新の配布版:** [ZIP 版アプリをダウンロード](https://github.com/kantaro4123/qwen-tts-jp-starter/releases/latest/download/qwen-tts-jp-starter-macos-app.zip)

![アプリ画面](docs/screenshots/app-home.png)

## これでできること

- 参照音声を使ったボイスクローン
- 参照動画からの音声取り出し
- 切り出し開始・終了秒の指定
- 前後の無音の自動カット
- 参照素材の簡単な品質チェック
- 多言語の読み上げ
- `faster-whisper` によるローカル文字起こし
- macOS アプリ版とブラウザ版の両対応
- GitHub Release を見てのアプリ内アップデート

## いちばん簡単な始め方

### 1. ZIP 版アプリを使う

いちばん簡単なのは `ZIP` 版です。  
こちらは **Python を別で入れなくても動く、内蔵ランタイム付き `.app`** として配布しています。  
`DMG` より Gatekeeper の確認が 1 回で済みやすいので、今はこちらを標準にしています。

1. [最新の ZIP 版アプリをダウンロード](https://github.com/kantaro4123/qwen-tts-jp-starter/releases/latest/download/qwen-tts-jp-starter-macos-app.zip) します
2. ダウンロードした `qwen-tts-jp-starter-macos-app.zip` をダブルクリックして展開します
3. 出てきた `かんたんボイスクローン.app` を `Applications` に移動します
4. `Applications` から `かんたんボイスクローン.app` を開きます
5. 最初だけアプリの `セットアップする` を押します
6. 準備が終わったら `起動する` を押します

アプリ版では、起動後もブラウザではなくアプリ内の画面でそのまま使えます。

最初の起動で警告が出たら、次の順番で進めてください。

1. アプリを `右クリック`
2. `開く` を選ぶ
3. 確認ダイアログでもう一度 `開く` を選ぶ

それでも開けない場合は、`システム設定 > プライバシーとセキュリティ` の `このまま開く` を使ってください。

### 2. DMG 版を使う

`ZIP` 版が使えない場合だけ `DMG` 版も使えます。

1. [最新の DMG をダウンロード](https://github.com/kantaro4123/qwen-tts-jp-starter/releases/latest/download/qwen-tts-jp-starter-macos.dmg) します
2. `かんたんボイスクローン.app` を `Applications` にドラッグします
3. `Applications` からアプリを開きます

`DMG` 版は、環境によっては `DMG` と `.app` の両方で確認が出ることがあります。できるだけ `ZIP` 版をおすすめします。

### 3. ソース版をブラウザで使う

ソース版では `run.command` を実行すると、ローカルのブラウザで UI が開きます。  
**ブラウザ版もアプリ版と同じ UI をベースにしており、導線や見た目は揃えています。**

```bash
git clone https://github.com/kantaro4123/qwen-tts-jp-starter.git
cd qwen-tts-jp-starter
chmod +x setup.command run.command
./setup.command
./run.command
```

通常はブラウザが自動で開きます。開かない場合だけ [http://127.0.0.1:7860](http://127.0.0.1:7860) を開いてください。

## 使い方

1. `参照音声` または `動画` を入れます
2. 必要なら `切り出し開始` と `切り出し終了` を指定します
3. `素材を整えて確認する` を押して、整えた参照音声を確認します
4. `自動文字起こしする` を押すか、参照音声の文字起こしを入力します
5. `読ませたい文章` を入力します
6. `読み上げ言語` を選びます
7. `音声を生成する` を押します

## きれいに作るコツ

- 参照音声は **3秒以上** を目安にしてください
- 精度を上げたいなら、**30秒前後のきれいな音声** も有効です
- 1人だけが話している素材を使ってください
- BGM や雑音は少ない方が安定します
- 参照テキストは、省略せず実際の音声どおりに入力してください
- 最初は短い文章で試すと成功しやすいです

## 文字起こしについて

このリポジトリでは、文字起こしは **`faster-whisper` によるローカル実行** を前提にしています。

- アプリ版: 初回セットアップで一緒に入ります
- ソース版: `./setup.command` で一緒に入ります
- 入れ直したいときだけ `文字起こしを入れ直す` または `./install_local_asr.command` を使います
- モデルサイズは `base / small / medium` から選べます
- 標準のおすすめは `small` です

## 対応環境

- macOS
- Apple Silicon の Mac
- ソース版は `Python 3.9 以上`
- ソース版の推奨は `Python 3.12`

アプリ版は Python を内蔵しているので、通常は別途 Python を入れなくても使えます。

## 推奨スペック

- Apple Silicon の Mac
- メモリ 16GB 以上推奨
- 空きストレージ 15GB 以上推奨

目安:

- `16GB` メモリ: まず快適に試しやすいライン
- `8GB` メモリ: 動く可能性はありますが、かなり重くなったり不安定になりやすいです
- Apple Silicon では、VRAM より共有メモリの余裕が重要です

## ソース版セットアップで時間がかかる理由

`./setup.command` は、依存関係のインストールに加えて、既定では `Qwen-TTS` モデルの事前ダウンロードまで行います。  
そのため、**初回はかなり時間がかかることがあります。**

止まったように見えても、そのまま待ってください。  
モデルの事前ダウンロードをあとに回したい場合は、次も使えます。

```bash
QWEN_TTS_PREFETCH_MODEL=0 ./setup.command
```

## よくあるつまずき

### アプリが開けない

Apple Developer の署名・公証なしでも配布できるようにしているため、初回起動時に macOS の警告が出ることがあります。  
`ZIP` 版の方が、`DMG` よりこの確認が 1 回で済みやすいです。

対処:

1. アプリを `右クリック`
2. `開く` を選ぶ
3. 確認ダイアログでもう一度 `開く` を選ぶ

それでも開けない場合は、`システム設定 > プライバシーとセキュリティ` の `このまま開く` を使ってください。

### 動画から音声を取り出せない

`ffmpeg` が必要です。

```bash
brew install ffmpeg
```

### 声が別人っぽくなる

- 参照音声が短すぎる
- 雑音が多い
- 複数人が入っている
- 参照テキストが少しでもズレている

このどれかで起こりやすいです。  
まずは 10 秒前後、その次に 20〜30 秒前後のきれいな音声で試してください。

### 状態をまとめて確認したい

```bash
./doctor.command
```

このコマンドでは、次をまとめて確認できます。

- `.venv` があるか
- 主要な Python パッケージが読めるか
- `faster-whisper` が入っているか
- `ffmpeg` が見つかるか
- 同梱モデルマップの状態

## モデル設定

- `Qwen-TTS`: `高精度 1.7B / 軽量 0.6B`
- `faster-whisper`: `base / small / medium`
- 標準の `Qwen-TTS` は `高精度 1.7B`
- 標準の `faster-whisper` は `small`

## macOS アプリ化 / ZIP / DMG 化

配布用の standalone `.app` をビルドする前に、先に `./setup.command` を実行して `.venv` を作っておいてください。

```bash
./scripts/build_launcher_app.sh
./scripts/build_zip.sh
./scripts/build_dmg.sh
```

詳しくは次を見てください。

- [docs/dmg-packaging.md](docs/dmg-packaging.md)
- [docs/signing-notarization.md](docs/signing-notarization.md)
- [docs/release-checklist.md](docs/release-checklist.md)

## GitHub に公開する流れ

```bash
git init
git add .
git commit -m "Initial commit"
gh repo create qwen-tts-jp-starter --public --source=. --remote=origin --push
```

## ライセンス

`Qwen-TTS` 本体や関連モデルの利用条件は、それぞれの配布元ライセンスを確認してください。  
このラッパー部分の扱いは [LICENSE](LICENSE) を見てください。
