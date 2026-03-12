from __future__ import annotations

import json
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / 'config' / 'settings.json'
OUTPUTS_DIR = ROOT / 'outputs'
MODEL_MAP_ENV = os.environ.get('QWEN_TTS_MODEL_MAP_PATH', '').strip()


def ok(label: str, detail: str) -> str:
    return f'[OK] {label}: {detail}'


def warn(label: str, detail: str) -> str:
    return f'[WARN] {label}: {detail}'


def fail(label: str, detail: str) -> str:
    return f'[FAIL] {label}: {detail}'


def read_settings() -> dict:
    if not CONFIG_PATH.exists():
        return {}
    try:
        return json.loads(CONFIG_PATH.read_text(encoding='utf-8'))
    except Exception:
        return {}


def check_python(lines: list[str]) -> None:
    lines.append(ok('Python', sys.version.split()[0]))


def check_venv(lines: list[str]) -> None:
    venv = ROOT / '.venv'
    if not venv.exists():
        lines.append(fail('.venv', '見つかりません。setup.command を実行してください。'))
        return
    python_bin = venv / 'bin' / 'python'
    if python_bin.exists():
        lines.append(ok('.venv', str(python_bin)))
    else:
        lines.append(warn('.venv', 'フォルダはありますが Python 実行ファイルが見つかりません。'))


def check_runtime_settings(lines: list[str]) -> None:
    settings = read_settings()
    if not settings:
        lines.append(warn('設定', 'config/settings.json がまだありません。初回セットアップ前なら正常です。'))
        return
    lines.append(ok('Qwen-TTS モデル', settings.get('qwen_tts_model_id', '未設定')))
    lines.append(ok('ローカルASR モデル', settings.get('local_asr_model', '未設定')))


def check_python_packages(lines: list[str]) -> None:
    try:
        import gradio  # noqa: F401
        import qwen_tts  # noqa: F401
        import soundfile  # noqa: F401
        lines.append(ok('主要Pythonパッケージ', 'gradio / qwen_tts / soundfile'))
    except Exception as exc:
        lines.append(fail('主要Pythonパッケージ', f'読み込み失敗: {exc}'))

    try:
        import faster_whisper  # noqa: F401
        lines.append(ok('ローカルASR', 'faster-whisper は利用可能です'))
    except Exception:
        lines.append(warn('ローカルASR', 'faster-whisper は未インストールです。必要なら install_local_asr.command を実行してください。'))


def check_ffmpeg(lines: list[str]) -> None:
    ffmpeg = shutil.which('ffmpeg')
    if ffmpeg:
        lines.append(ok('ffmpeg', ffmpeg))
    else:
        lines.append(warn('ffmpeg', '未検出です。動画から音声を取り出すなら brew install ffmpeg を実行してください。'))


def check_model_map(lines: list[str]) -> None:
    if not MODEL_MAP_ENV:
        lines.append(warn('同梱モデルマップ', 'QWEN_TTS_MODEL_MAP_PATH は未設定です。通常の Hugging Face ダウンロードを使います。'))
        return
    path = Path(MODEL_MAP_ENV)
    if not path.exists():
        lines.append(fail('同梱モデルマップ', f'指定ファイルが見つかりません: {path}'))
        return
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except Exception as exc:
        lines.append(fail('同梱モデルマップ', f'JSON 読み込み失敗: {exc}'))
        return
    if not isinstance(data, dict) or not data:
        lines.append(warn('同梱モデルマップ', '内容が空です。'))
        return
    usable = []
    missing = []
    for model_id, local_path in data.items():
        resolved_path = Path(local_path)
        if not resolved_path.is_absolute():
            resolved_path = (path.parent / resolved_path).resolve()
        if resolved_path.exists():
            usable.append(model_id)
        else:
            missing.append(f'{model_id} -> {resolved_path}')
    if usable:
        lines.append(ok('同梱モデルマップ', ', '.join(usable)))
    if missing:
        lines.append(warn('同梱モデルマップ不足', ' / '.join(missing)))


def check_outputs(lines: list[str]) -> None:
    OUTPUTS_DIR.mkdir(parents=True, exist_ok=True)
    lines.append(ok('出力フォルダ', str(OUTPUTS_DIR.resolve())))


def main() -> None:
    lines: list[str] = []
    check_python(lines)
    check_venv(lines)
    check_runtime_settings(lines)
    check_python_packages(lines)
    check_ffmpeg(lines)
    check_model_map(lines)
    check_outputs(lines)
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
