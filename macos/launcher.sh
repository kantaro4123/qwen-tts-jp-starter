#!/bin/zsh
set -euo pipefail

APP_DIR=$(cd "$(dirname "$0")/../.." && pwd)
PROJECT_DIR=$(cd "$APP_DIR/.." && pwd)
ACTION="${1:-run}"
SAVE_SETTINGS_SCRIPT="$PROJECT_DIR/scripts/save_settings.py"
DEFAULT_QWEN_MODEL_ID="Qwen/Qwen3-TTS-12Hz-1.7B-Base"
DEFAULT_LOCAL_ASR_MODEL="small"

if [ ! -f "$PROJECT_DIR/run.command" ]; then
  osascript -e 'display alert "起動に失敗しました" message "run.command が見つかりませんでした。配布フォルダの中身を動かしているか確認してください。"' || true
  exit 1
fi

cd "$PROJECT_DIR"

choose_models() {
  local qwen_choice
  local asr_choice
  qwen_choice=$(osascript <<'APPLESCRIPT'
set picked to choose from list {"高精度 1.7B", "軽量 0.6B"} with prompt "最初に使う Qwen-TTS モデルを選んでください" default items {"高精度 1.7B"}
if picked is false then
  return ""
end if
return item 1 of picked
APPLESCRIPT
)
  if [ -z "$qwen_choice" ]; then
    exit 0
  fi
  asr_choice=$(osascript <<'APPLESCRIPT'
set picked to choose from list {"small", "base", "medium"} with prompt "ローカル文字起こしの初期モデルを選んでください" default items {"small"}
if picked is false then
  return ""
end if
return item 1 of picked
APPLESCRIPT
)
  if [ -z "$asr_choice" ]; then
    exit 0
  fi

  local qwen_model_id="$DEFAULT_QWEN_MODEL_ID"
  if [ "$qwen_choice" = "軽量 0.6B" ]; then
    qwen_model_id="Qwen/Qwen3-TTS-12Hz-0.6B-Base"
  fi

  python3 "$SAVE_SETTINGS_SCRIPT" --qwen-model-id "$qwen_model_id" --local-asr-model "$asr_choice" >/dev/null
}

if [ "$ACTION" = "setup" ]; then
  choose_models
  osascript -e 'display dialog "初回セットアップを始めます。数分かかることがあります。" buttons {"OK"} default button "OK"' || true
  echo "初回セットアップを始めます..."
  ./setup.command
  osascript -e 'display notification "初回セットアップが終わりました。" with title "かんたんボイスクローン"' || true
  exit 0
fi

if [ "$ACTION" = "update" ]; then
  osascript -e 'display dialog "更新を始めます。ローカル変更がある場合は失敗することがあります。" buttons {"OK"} default button "OK"' || true
  echo "更新を始めます..."
  if [ ! -d ".git" ]; then
    echo "この配布フォルダは Git 管理されていません。更新機能は使えません。"
    exit 1
  fi
  git pull
  ./setup.command
  osascript -e 'display notification "更新が終わりました。" with title "かんたんボイスクローン"' || true
  exit 0
fi

if [ "$ACTION" = "install-local-asr" ]; then
  osascript -e 'display dialog "ローカル文字起こしを追加します。初回は数分かかることがあります。" buttons {"OK"} default button "OK"' || true
  echo "ローカル文字起こしを追加します..."
  ./install_local_asr.command
  osascript -e 'display notification "ローカル文字起こしの追加が終わりました。" with title "かんたんボイスクローン"' || true
  exit 0
fi

if [ ! -d ".venv" ]; then
  choose_models
  osascript -e 'display dialog "初回セットアップを始めます。数分かかることがあります。" buttons {"OK"} default button "OK"' || true
  echo "初回セットアップを始めます..."
  ./setup.command
  osascript -e 'display notification "初回セットアップが終わりました。" with title "かんたんボイスクローン"' || true
fi

osascript -e 'display notification "アプリを起動します。ブラウザが開くまで少し待ってください。" with title "かんたんボイスクローン"' || true
./run.command
