# ASR 候補メモ

## 用語

- `TTS`: Text to Speech
- `ASR`: Automatic Speech Recognition

このプロジェクトで欲しいのは、参照音声の文字起こしなので `ASR` です。

## 候補

### 1. faster-whisper

- いちばん現実的
- ローカル組み込みしやすい
- 速度と精度のバランスが良い
- このリポジトリではまずこれを採用

### 2. openai/whisper

- 元の Whisper 実装
- 実績は強い
- ただし、そのままだと `faster-whisper` より重くなりやすい

### 3. FunASR

- 多言語・日本語でも候補になる
- ただし、このスターターにすぐ組み込むには少し設計が必要

## このリポジトリでの方針

- API キーがある場合: OpenAI API 文字起こし
- API キーがない場合: `faster-whisper`
- さらに先の改善で、言語ごとにバックエンドの出し分けも検討する
