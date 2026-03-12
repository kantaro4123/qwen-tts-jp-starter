# qwen-tts-jp-starter

`Qwen-TTS` を、日本語でわかりやすく始めるための初心者向けスターターです。  
Apple Silicon の Mac で、できるだけ迷わずボイスクローンを試せることを目的にしています。

![アプリ画面](docs/screenshots/app-home.png)

## できること

- 参照音声をアップロードして、声の雰囲気をまねた音声を作る
- 日本語UIで手順を見ながら試せる
- ローカルで動かせる

## 対応環境

- macOS
- Apple Silicon の Mac
- Python 3.9 以上

推奨は `Python 3.12` です。  
このスターターは `Python 3.9` 以上で動く想定ですが、説明や確認は `Python 3.12` を基準にしています。

最初の公開版では、初心者向けに対象を絞っています。  
Windows 対応や多機能化は、動作のわかりやすさを優先していったん外しています。

## まず最初にやること

このアプリは、最初にこのリポジトリのファイル一式を Mac に入れてから使います。  
そのあとで `setup.command` を実行して、必要なものを自動でインストールします。

`cd qwen-tts-jp-starter` は「インストール」ではなく、`qwen-tts-jp-starter` というフォルダに入るためのコマンドです。

## いちばん簡単な始め方

### 方法A: GitHub から ZIP をダウンロードする

1. このページを開きます  
   [https://github.com/kantaro4123/qwen-tts-jp-starter](https://github.com/kantaro4123/qwen-tts-jp-starter)
2. 緑色の `Code` ボタンを押します
3. `Download ZIP` を押します
4. ダウンロードした ZIP ファイルをダブルクリックして展開します
5. 展開してできた `qwen-tts-jp-starter` フォルダを開きます
6. `setup.command` をダブルクリックします
7. セットアップが終わったら `run.command` をダブルクリックします

通常はブラウザが自動で開きます。開かない場合は [http://127.0.0.1:7860](http://127.0.0.1:7860) を開いてください。

### 方法B: ターミナルでダウンロードする

ターミナルを開いて、上から順番にそのまま実行してください。

```bash
git clone https://github.com/kantaro4123/qwen-tts-jp-starter.git
cd qwen-tts-jp-starter
chmod +x setup.command run.command
./setup.command
./run.command
```

それぞれの意味:

- `git clone ...` は GitHub からファイル一式をダウンロードします
- `cd qwen-tts-jp-starter` は、そのフォルダの中に移動します
- `chmod +x ...` は、起動用ファイルを実行できる状態にします
- `./setup.command` は、必要なライブラリをインストールします
- `./run.command` は、アプリを起動します

## ターミナルで細かく始める手順

### 1. ターミナルを開く

`アプリケーション` → `ユーティリティ` → `ターミナル` から開けます。

### 2. GitHub からファイルをダウンロードする

```bash
git clone https://github.com/kantaro4123/qwen-tts-jp-starter.git
```

### 3. ダウンロードしたフォルダに移動する

```bash
cd qwen-tts-jp-starter
```

### 4. 実行できるようにする

```bash
chmod +x setup.command run.command
```

### 5. セットアップする

Finder から `setup.command` をダブルクリックするか、ターミナルで次を実行します。

```bash
./setup.command
```

初回は少し時間がかかります。  
これは必要なライブラリやモデルの準備をしているためです。

### 6. アプリを起動する

Finder から `run.command` をダブルクリックするか、ターミナルで次を実行します。

```bash
./run.command
```

通常はブラウザが自動で開きます。開かない場合は [http://127.0.0.1:7860](http://127.0.0.1:7860) を開いてください。

### 7. 終わるとき

ターミナルで `Ctrl + C` を押すと停止できます。

## 使い方

1. `参照音声` に 3 秒以上の音声を入れます。精度を上げたいなら 30 秒前後も有効です。
2. `参照音声の文字起こし` に、その音声で実際に話している内容を正確に入れます。
3. `読ませたい文章` に、生成したい文章を入れます。
4. `音声生成` を押します。

## きれいに作るコツ

- 参照音声は 3 秒以上あるものを使う
- 精度を上げたいなら、30 秒前後のきれいな音声も有効
- 無音やBGMが少ない音声を使う
- 参照音声は1人だけが話しているものにする
- 参照テキストは省略せず、実際の発話どおりに書く
- 最初は短い文章で試す

## よくあるつまずき

### 初回起動が遅い

初回はモデルのダウンロードが入るので時間がかかります。  
2回目以降は速くなります。

### うまく起動しない

- `python3` が 3.9 以上か確認してください
- できれば `python3.12` を使ってください
- Apple Silicon の Mac か確認してください
- 依存関係が壊れた場合は、`.venv` を削除して `./setup.command` をやり直してください
- `git: command not found` と出る場合は、まず Xcode Command Line Tools を入れてください

```bash
python3 --version
xcode-select --install
```

## 公開・改造のヒント

- GitHub で公開するときは、トップにスクリーンショットを載せると伝わりやすいです
- `app.py` の文言を変えるだけでも、日本語UIはかなり調整できます
- `QWEN_TTS_MODEL_ID` 環境変数で別モデルに差し替えられます

## GitHub に公開する流れ

```bash
git init
git add .
git commit -m "Initial commit"
gh repo create qwen-tts-jp-starter --public --source=. --remote=origin --push
```

リポジトリ名を変えたい場合は、最後の `qwen-tts-jp-starter` の部分だけ好きな名前に変えてください。

## 注意

本人の声、または明確な許可がある声だけを使ってください。  
なりすまし、詐欺、嫌がらせ、権利侵害につながる使い方は避けてください。
