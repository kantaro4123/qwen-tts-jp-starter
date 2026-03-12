#!/bin/zsh
set -euo pipefail

APP_DIR=$(cd "$(dirname "$0")/../.." && pwd)
PROJECT_DIR=$(cd "$APP_DIR/.." && pwd)
ACTION="${1:-run}"
SAVE_SETTINGS_SCRIPT="$PROJECT_DIR/scripts/save_settings.py"
DEFAULT_QWEN_MODEL_ID="Qwen/Qwen3-TTS-12Hz-1.7B-Base"
DEFAULT_LOCAL_ASR_MODEL="small"
PYTHON_DOWNLOAD_URL="https://www.python.org/downloads/macos/"
RELEASES_URL="https://github.com/kantaro4123/qwen-tts-jp-starter/releases/latest"
README_PATH="$PROJECT_DIR/README.md"

if [ ! -f "$PROJECT_DIR/run.command" ]; then
  osascript -e 'display alert "起動に失敗しました" message "run.command が見つかりませんでした。配布フォルダの中身を動かしているか確認してください。"' || true
  exit 1
fi

cd "$PROJECT_DIR"

pick_python() {
  for candidate in python3.12 python3.11 python3.10 python3.9 python3; do
    if ! command -v "$candidate" >/dev/null 2>&1; then
      continue
    fi
    if "$candidate" - <<'PY' >/dev/null 2>&1
import sys
sys.exit(0 if sys.version_info >= (3, 9) else 1)
PY
    then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

show_dialog() {
  local title="$1"
  local message="$2"
  osascript -e "display dialog \"$message\" with title \"$title\" buttons {\"OK\"} default button \"OK\"" || true
}

notify() {
  local message="$1"
  osascript -e "display notification \"$message\" with title \"かんたんボイスクローン\"" || true
}

offer_python_download() {
  local response
  response=$(osascript <<APPLESCRIPT
display dialog "Python 3.9 以上が見つかりませんでした。先に Python を入れる必要があります。ダウンロードページを開きますか？" with title "Python が必要です" buttons {"キャンセル", "ダウンロードページを開く"} default button "ダウンロードページを開く"
button returned of result
APPLESCRIPT
)
  if [ "$response" = "ダウンロードページを開く" ]; then
    open "$PYTHON_DOWNLOAD_URL"
  fi
}

ensure_python_for_setup() {
  local python_bin
  python_bin=$(pick_python || true)
  if [ -z "$python_bin" ]; then
    offer_python_download
    exit 1
  fi
}

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

if [ "$ACTION" = "help" ]; then
  open "$README_PATH"
  exit 0
fi

if [ "$ACTION" = "setup" ]; then
  ensure_python_for_setup
  choose_models
  show_dialog "初回セットアップ" "初回セットアップを始めます。モデルのダウンロードが入るので数分かかることがあります。"
  echo "初回セットアップを始めます..."
  ./setup.command
  notify "初回セットアップが終わりました。次は『起動』を選んでください。"
  exit 0
fi

if [ "$ACTION" = "update" ]; then
  ensure_python_for_setup
  show_dialog "更新" "更新を始めます。ローカル変更がある場合は失敗することがあります。"
  echo "更新を始めます..."
  if [ ! -d ".git" ]; then
    response=$(osascript <<APPLESCRIPT
display dialog "この配布版は Git 管理されていないため、アプリ内更新は使えません。最新の配布ページを開きますか？" with title "更新方法" buttons {"閉じる", "配布ページを開く"} default button "配布ページを開く"
button returned of result
APPLESCRIPT
)
    if [ "$response" = "配布ページを開く" ]; then
      open "$RELEASES_URL"
    fi
    echo "この配布フォルダは Git 管理されていません。GitHub Releases から最新版をダウンロードしてください。"
    exit 1
  fi
  git pull
  ./setup.command
  notify "更新が終わりました。"
  exit 0
fi

if [ "$ACTION" = "install-local-asr" ]; then
  ensure_python_for_setup
  show_dialog "ローカル文字起こしを追加" "ローカル文字起こしを追加します。初回は数分かかることがあります。"
  echo "ローカル文字起こしを追加します..."
  ./install_local_asr.command
  notify "ローカル文字起こしの追加が終わりました。"
  exit 0
fi

if [ ! -d ".venv" ]; then
  ensure_python_for_setup
  choose_models
  show_dialog "初回セットアップ" "まだセットアップされていないので、このまま初回セットアップを始めます。"
  echo "初回セットアップを始めます..."
  ./setup.command
  notify "初回セットアップが終わりました。ブラウザを開いて起動します。"
fi

if [ ! -f "$README_PATH" ]; then
  echo "README.md が見つかりませんでした。配布フォルダの中身をそのまま使っているか確認してください。"
fi

notify "アプリを起動します。ブラウザが開くまで少し待ってください。"
./run.command
