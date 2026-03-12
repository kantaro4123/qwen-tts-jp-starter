from __future__ import annotations

import os
import json
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import gradio as gr
import soundfile as sf
import torch
from pydub import AudioSegment
from pydub.silence import detect_nonsilent
from qwen_tts import Qwen3TTSModel


DEFAULT_MODEL_ID = "Qwen/Qwen3-TTS-12Hz-1.7B-Base"
DEFAULT_LANGUAGE = "Japanese"
DEFAULT_LANGUAGE_LABEL = "日本語"
LOCAL_ASR_MODEL = os.environ.get("QWEN_TTS_LOCAL_ASR_MODEL", "small")
SETTINGS_PATH = Path("config/settings.json")
QWEN_TTS_MODEL_CHOICES = {
    "高精度 1.7B": "Qwen/Qwen3-TTS-12Hz-1.7B-Base",
    "軽量 0.6B": "Qwen/Qwen3-TTS-12Hz-0.6B-Base",
}
LOCAL_ASR_MODEL_CHOICES = ["base", "small", "medium"]
LANGUAGE_LABEL_TO_VALUE = {
    "自動判定": "Auto",
    "中国語": "Chinese",
    "英語": "English",
    "ドイツ語": "German",
    "イタリア語": "Italian",
    "ポルトガル語": "Portuguese",
    "スペイン語": "Spanish",
    "日本語": "Japanese",
    "韓国語": "Korean",
    "フランス語": "French",
    "ロシア語": "Russian",
}
SUPPORTED_LANGUAGES = list(LANGUAGE_LABEL_TO_VALUE.keys())
DEFAULT_OUTPUT_DIR = Path("outputs")
DEFAULT_REFERENCE_DIR = DEFAULT_OUTPUT_DIR / "references"
DEFAULT_GENERATED_DIR = DEFAULT_OUTPUT_DIR / "generated"
DEFAULT_GENERATION_KWARGS = {}
TARGET_REFERENCE_SAMPLE_RATE = 24000
TARGET_REFERENCE_DBFS = -20.0
TRANSCRIBE_BACKENDS = ["自動選択", "ローカル faster-whisper"]
TRANSCRIBE_LANGUAGE_HINTS = {
    "自動判定": "",
    "中国語": "zh",
    "英語": "en",
    "ドイツ語": "de",
    "イタリア語": "it",
    "ポルトガル語": "pt",
    "スペイン語": "es",
    "日本語": "ja",
    "韓国語": "ko",
    "フランス語": "fr",
    "ロシア語": "ru",
}


@dataclass
class AppConfig:
    model_id: str = DEFAULT_MODEL_ID
    host: str = os.environ.get("QWEN_TTS_HOST", "127.0.0.1")
    port: int = int(os.environ.get("QWEN_TTS_PORT", "7860"))
    output_dir: Path = Path(os.environ.get("QWEN_TTS_OUTPUT_DIR", str(DEFAULT_OUTPUT_DIR)))
    local_asr_model: str = LOCAL_ASR_MODEL


APP_CONFIG = AppConfig()
_MODEL: Optional[Qwen3TTSModel] = None


def load_model_path_overrides() -> dict[str, str]:
    mapping_path = os.environ.get("QWEN_TTS_MODEL_MAP_PATH", "").strip()
    if not mapping_path:
        return {}
    path = Path(mapping_path)
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    result: dict[str, str] = {}
    for model_id, local_path in data.items():
        if not isinstance(model_id, str) or not isinstance(local_path, str):
            continue
        resolved_local_path = Path(local_path)
        if not resolved_local_path.is_absolute():
            resolved_local_path = (path.parent / resolved_local_path).resolve()
        if resolved_local_path.exists():
            result[model_id] = str(resolved_local_path)
    return result


def ensure_settings_dir() -> None:
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)


def load_settings() -> dict:
    if not SETTINGS_PATH.exists():
        return {}
    try:
        return json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_settings(settings: dict) -> None:
    ensure_settings_dir()
    SETTINGS_PATH.write_text(json.dumps(settings, ensure_ascii=False, indent=2), encoding="utf-8")


def apply_settings() -> None:
    settings = load_settings()
    APP_CONFIG.model_id = settings.get("qwen_tts_model_id", os.environ.get("QWEN_TTS_MODEL_ID", DEFAULT_MODEL_ID))
    APP_CONFIG.local_asr_model = settings.get("local_asr_model", os.environ.get("QWEN_TTS_LOCAL_ASR_MODEL", LOCAL_ASR_MODEL))


def current_qwen_label() -> str:
    for label, model_id in QWEN_TTS_MODEL_CHOICES.items():
        if model_id == APP_CONFIG.model_id:
            return label
    return "高精度 1.7B"


apply_settings()


def detect_device() -> str:
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def load_model() -> Qwen3TTSModel:
    global _MODEL
    if _MODEL is not None:
        return _MODEL

    device = detect_device()
    source = load_model_path_overrides().get(APP_CONFIG.model_id, APP_CONFIG.model_id)
    model = Qwen3TTSModel.from_pretrained(
        source,
        device_map=device,
        dtype=torch.float32,
        attn_implementation="eager",
    )
    _MODEL = model
    return model


def validate_inputs(reference_audio: Optional[str], reference_text: str, target_text: str) -> Optional[str]:
    if not reference_audio:
        return "参照音声または参照動画をアップロードしてください。"
    if not reference_text.strip():
        return "参照音声で実際に話している内容を、参照テキストに入力してください。"
    if not target_text.strip():
        return "読ませたい文章を入力してください。"
    return None


def save_output_audio(waveform, sample_rate: int) -> str:
    DEFAULT_GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(prefix="qwen-tts-jp-", suffix=".wav", dir=DEFAULT_GENERATED_DIR)
    os.close(fd)
    sf.write(temp_path, waveform, sample_rate)
    return temp_path


def save_reference_audio(audio: AudioSegment) -> str:
    DEFAULT_REFERENCE_DIR.mkdir(parents=True, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(prefix="qwen-tts-ref-", suffix=".wav", dir=DEFAULT_REFERENCE_DIR)
    os.close(fd)
    audio.export(temp_path, format="wav")
    return temp_path


def standardize_reference_audio(audio: AudioSegment) -> AudioSegment:
    standardized = audio.set_channels(1).set_frame_rate(TARGET_REFERENCE_SAMPLE_RATE)
    if standardized.dBFS != float("-inf"):
        gain = TARGET_REFERENCE_DBFS - standardized.dBFS
        gain = max(-12.0, min(12.0, gain))
        standardized = standardized.apply_gain(gain)
    return standardized


def format_duration(milliseconds: int) -> str:
    return f"{milliseconds / 1000:.1f}秒"


def analyze_reference_audio(audio: AudioSegment) -> list[str]:
    notes: list[str] = []
    duration_ms = len(audio)
    if duration_ms < 3000:
        notes.append("短すぎます。3秒以上ある方が安定しやすいです。")
    elif duration_ms < 8000:
        notes.append("使えますが、精度を上げたいなら 8〜15 秒くらいも試してください。")
    elif duration_ms <= 30000:
        notes.append("長さはかなり良いです。")
    else:
        notes.append("少し長めです。必要な部分だけに切ると安定しやすいです。")

    if audio.dBFS == float("-inf"):
        notes.append("ほぼ無音です。別の素材を使ってください。")
    elif audio.dBFS < -32:
        notes.append("音量が小さめです。はっきり聞こえる素材の方が良いです。")

    regions = detect_nonsilent(audio, min_silence_len=200, silence_thresh=max(audio.dBFS - 16, -50))
    spoken_ms = sum((end - start) for start, end in regions) if regions else 0
    if duration_ms > 0:
        silence_ratio = 1 - (spoken_ms / duration_ms)
        if silence_ratio > 0.45:
            notes.append("無音が多めです。切り出しや自動無音カットが有効です。")

    return notes


def ensure_ffmpeg() -> None:
    if shutil.which("ffmpeg") is None:
        raise RuntimeError(
            "動画から音声を取り出すには ffmpeg が必要です。Homebrew を使うなら `brew install ffmpeg` を実行してください。"
        )


def extract_audio_from_video(video_path: str) -> str:
    ensure_ffmpeg()
    DEFAULT_REFERENCE_DIR.mkdir(parents=True, exist_ok=True)
    fd, audio_path = tempfile.mkstemp(prefix="qwen-tts-video-", suffix=".wav", dir=DEFAULT_REFERENCE_DIR)
    os.close(fd)
    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        video_path,
        "-vn",
        "-ac",
        "1",
        "-ar",
        "24000",
        audio_path,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError("動画から音声を取り出せませんでした。別の動画ファイルで試してください。")
    return audio_path


def auto_trim_audio(audio: AudioSegment) -> AudioSegment:
    if len(audio) == 0:
        return audio

    silence_threshold = audio.dBFS - 16 if audio.dBFS != float("-inf") else -50
    silence_threshold = max(silence_threshold, -50)
    regions = detect_nonsilent(audio, min_silence_len=200, silence_thresh=silence_threshold)
    if not regions:
        return audio

    start_ms = regions[0][0]
    end_ms = regions[-1][1]
    return audio[start_ms:end_ms]


def build_reference_audio(
    reference_audio: Optional[str],
    reference_video: Optional[str],
    trim_start_sec: float,
    trim_end_sec: float,
    auto_trim_silence: bool,
) -> tuple[str, str]:
    if reference_audio:
        source_path = reference_audio
        source_label = "アップロード音声"
    elif reference_video:
        source_path = extract_audio_from_video(reference_video)
        source_label = "アップロード動画"
    else:
        raise ValueError("参照音声または参照動画をアップロードしてください。")

    audio = AudioSegment.from_file(source_path)
    start_ms = max(0, int(trim_start_sec * 1000))
    end_ms = int(trim_end_sec * 1000) if trim_end_sec > 0 else len(audio)
    end_ms = min(end_ms, len(audio))
    if start_ms >= end_ms:
        raise ValueError("切り出し範囲が不正です。開始秒と終了秒を見直してください。")

    prepared = audio[start_ms:end_ms]
    if auto_trim_silence:
        prepared = auto_trim_audio(prepared)
    prepared = standardize_reference_audio(prepared)

    if len(prepared) == 0:
        raise ValueError("切り出した結果が空になりました。切り出し範囲を見直してください。")

    output_path = save_reference_audio(prepared)
    duration_sec = len(prepared) / 1000
    notes = analyze_reference_audio(prepared)
    status_lines = [
        "参照素材を整えました。",
        f"元の入力: {source_label}",
        f"長さ: {duration_sec:.1f}秒",
    ]
    if notes:
        status_lines.append("チェック結果:")
        status_lines.extend(f"- {note}" for note in notes)
    status_lines.append("- 保存前にモノラル化・24kHz化・軽い音量調整を行っています。")
    status = "\n".join(status_lines)
    return status, output_path


def prepare_reference_audio(
    reference_audio: Optional[str],
    reference_video: Optional[str],
    trim_start_sec: float,
    trim_end_sec: float,
    auto_trim_silence: bool,
) -> tuple[str, Optional[str], Optional[str]]:
    try:
        status, output_path = build_reference_audio(
            reference_audio=reference_audio,
            reference_video=reference_video,
            trim_start_sec=trim_start_sec,
            trim_end_sec=trim_end_sec,
            auto_trim_silence=auto_trim_silence,
        )
    except Exception as exc:
        return f"参照素材の準備に失敗しました: {exc}", None, None

    return status, output_path, output_path


def transcribe_reference_audio(
    reference_audio: Optional[str],
    reference_video: Optional[str],
    prepared_reference_audio: Optional[str],
    target_language: str,
    transcription_backend_selector: str,
    trim_start_sec: float,
    trim_end_sec: float,
    auto_trim_silence: bool,
) -> tuple[str, Optional[str], Optional[str], str]:
    backend_status = ""
    resolved_reference_audio = prepared_reference_audio
    status_prefix = "整えた参照音声をそのまま使いました。"
    if not resolved_reference_audio:
        try:
            status_prefix, resolved_reference_audio = build_reference_audio(
                reference_audio=reference_audio,
                reference_video=reference_video,
                trim_start_sec=trim_start_sec,
                trim_end_sec=trim_end_sec,
                auto_trim_silence=auto_trim_silence,
            )
        except Exception as exc:
            return f"参照素材の準備に失敗しました: {exc}", None, None, ""

    language_hint = TRANSCRIBE_LANGUAGE_HINTS.get(target_language, "")

    try:
        from faster_whisper import WhisperModel
    except Exception:
        return (
            "ローカル文字起こし（faster-whisper）は別途インストールが必要です。\n"
            "アプリ版: 設定画面の「文字起こしを入れ直す」ボタンを押してください。\n"
            "ソース版: ターミナルで `./install_local_asr.command` を実行してください。\n"
            "インストール済みの場合はアプリを再起動してください。",
            resolved_reference_audio,
            resolved_reference_audio,
            "",
        )
    compute_type = "int8"
    model = WhisperModel(APP_CONFIG.local_asr_model, device="cpu", compute_type=compute_type)
    segments, _info = model.transcribe(
        resolved_reference_audio,
        language=(language_hint or None),
        vad_filter=True,
        condition_on_previous_text=False,
    )
    transcript = "".join(segment.text for segment in segments).strip()
    backend_status = f"ローカル faster-whisper ({APP_CONFIG.local_asr_model})"

    if not transcript:
        return (
            "自動文字起こしの結果が空でした。別の素材か手入力で試してください。",
            resolved_reference_audio,
            resolved_reference_audio,
            "",
        )

    return (
        f"{status_prefix}\n自動文字起こしが完了しました。方式: {backend_status}\n内容を確認して、必要なら少し修正してください。",
        resolved_reference_audio,
        resolved_reference_audio,
        transcript,
    )


def generate_voice_clone(
    reference_audio: Optional[str],
    reference_video: Optional[str],
    prepared_reference_audio: Optional[str],
    reference_text: str,
    target_text: str,
    target_language: str,
    trim_start_sec: float,
    trim_end_sec: float,
    auto_trim_silence: bool,
) -> tuple[str, Optional[str], Optional[str]]:
    if prepared_reference_audio:
        resolved_reference_audio = prepared_reference_audio
    else:
        try:
            _, resolved_reference_audio = build_reference_audio(
                reference_audio=reference_audio,
                reference_video=reference_video,
                trim_start_sec=trim_start_sec,
                trim_end_sec=trim_end_sec,
                auto_trim_silence=auto_trim_silence,
            )
        except Exception as exc:
            return f"参照素材の準備に失敗しました: {exc}", None, None

    error = validate_inputs(resolved_reference_audio, reference_text, target_text)
    if error:
        return error, prepared_reference_audio, None

    model = load_model()
    wavs, sample_rate = model.generate_voice_clone(
        text=target_text.strip(),
        language=LANGUAGE_LABEL_TO_VALUE.get(target_language, DEFAULT_LANGUAGE),
        ref_audio=resolved_reference_audio,
        ref_text=reference_text.strip(),
        non_streaming_mode=True,
        **DEFAULT_GENERATION_KWARGS,
    )
    output_path = save_output_audio(wavs[0], sample_rate)
    message = (
        "生成できました。下のプレイヤーで確認して、必要なら wav ファイルとして保存してください。"
    )
    return message, resolved_reference_audio, output_path


def fill_reference_text_example() -> str:
    return "おはようございます。今日は少しだけ自己紹介をします。"


def fill_target_text_example() -> str:
    return "こんにちは。これはボイスクローンのテストです。"


def open_output_folder() -> str:
    DEFAULT_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    subprocess.run(["open", str(DEFAULT_OUTPUT_DIR.resolve())], check=False)
    return f"出力フォルダを開きました: {DEFAULT_OUTPUT_DIR.resolve()}"


def save_model_settings(qwen_model_label: str, local_asr_model: str) -> str:
    global _MODEL
    model_id = QWEN_TTS_MODEL_CHOICES.get(qwen_model_label, DEFAULT_MODEL_ID)
    current_model_id = APP_CONFIG.model_id
    settings = load_settings()
    settings["qwen_tts_model_id"] = model_id
    settings["local_asr_model"] = local_asr_model
    save_settings(settings)
    APP_CONFIG.model_id = model_id
    APP_CONFIG.local_asr_model = local_asr_model
    if current_model_id != model_id:
        _MODEL = None
    return (
        "設定を保存しました。"
        f" Qwen-TTS: {qwen_model_label}"
        f" / ローカルASR: {local_asr_model}"
        " / Qwen-TTS の変更は次の生成時から反映されます。"
    )


def local_asr_installed() -> bool:
    try:
        import faster_whisper  # noqa: F401
        return True
    except Exception:
        return False


def build_settings_summary() -> str:
    installed = "インストール済み" if local_asr_installed() else "未インストール"
    return (
        "### 現在の設定\n"
        f"- Qwen-TTS: `{current_qwen_label()}`\n"
        f"- ローカルASR: `{APP_CONFIG.local_asr_model}`\n"
        f"- faster-whisper: `{installed}`\n"
    )


CSS = """
    :root {
      --page-bg: radial-gradient(circle at top left, #fff4e8 0%, #f4fbf6 42%, #eef5ff 100%);
      --card-bg: rgba(255, 255, 255, 0.88);
      --card-strong: rgba(255, 255, 255, 0.96);
      --card-border: rgba(47, 76, 63, 0.12);
      --headline: #1d2c24;
      --body: #355045;
      --muted: #6c8376;
      --accent: #2f7a53;
      --accent-soft: rgba(47, 122, 83, 0.1);
      --accent-2: #ca6a3d;
      --warning-bg: rgba(202, 106, 61, 0.08);
      --shadow: 0 20px 55px rgba(31, 50, 40, 0.08);
    }

    body, .gradio-container {
      background: var(--page-bg) !important;
      color: var(--body);
      font-family: "Hiragino Sans", "Yu Gothic", sans-serif;
    }

    .gradio-container {
      max-width: 1320px !important;
      margin: 0 auto !important;
      padding: 20px 18px 28px !important;
    }

    footer,
    .built-with,
    [data-testid="api-button"],
    [data-testid="settings-button"],
    button[aria-label="Settings"],
    button[aria-label="API"],
    .gradio-container .settings,
    .gradio-container .prose .md > h1 + p:last-child {
      display: none !important;
    }

    .app-shell {
      gap: 16px;
    }

    .hero {
      background: linear-gradient(145deg, rgba(255,255,255,0.95), rgba(248, 252, 249, 0.88));
      border: 1px solid var(--card-border);
      border-radius: 28px;
      padding: 30px 32px;
      box-shadow: var(--shadow);
      margin-bottom: 4px;
    }

    .hero-grid {
      display: grid;
      grid-template-columns: minmax(0, 1.6fr) minmax(280px, 0.9fr);
      gap: 22px;
      align-items: start;
    }

    .hero h1 {
      color: var(--headline);
      font-size: 2.45rem;
      line-height: 1.08;
      margin: 0 0 10px;
      letter-spacing: -0.02em;
    }

    .hero p, .hero li {
      color: var(--body);
      line-height: 1.7;
      margin: 0;
    }

    .hero-lead {
      font-size: 1.02rem;
      margin-bottom: 14px !important;
    }

    .hero-note {
      margin-top: 16px;
      padding: 14px 16px;
      border-radius: 16px;
      background: var(--warning-bg);
      border: 1px solid rgba(202, 106, 61, 0.16);
      font-size: 0.92rem;
    }

    .hero-side {
      display: grid;
      gap: 12px;
    }

    .summary-card {
      background: var(--card-strong);
      border: 1px solid var(--card-border);
      border-radius: 20px;
      padding: 18px 18px 16px;
    }

    .summary-title {
      font-size: 0.84rem;
      font-weight: 700;
      color: var(--muted);
      letter-spacing: 0.08em;
      text-transform: uppercase;
      margin-bottom: 12px;
    }

    .steps-overview {
      display: grid;
      gap: 10px;
    }

    .step-line {
      display: grid;
      grid-template-columns: 34px 1fr;
      gap: 12px;
      align-items: start;
    }

    .step-badge {
      width: 34px;
      height: 34px;
      border-radius: 50%;
      background: var(--accent);
      color: white;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      font-weight: 700;
      box-shadow: inset 0 -4px 10px rgba(0,0,0,0.12);
    }

    .step-line strong {
      display: block;
      color: var(--headline);
      margin-bottom: 2px;
      font-size: 0.97rem;
    }

    .step-line span {
      color: var(--muted);
      font-size: 0.88rem;
      line-height: 1.55;
    }

    .quick-facts {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
      margin-top: 14px;
    }

    .fact-pill {
      padding: 11px 12px;
      border-radius: 14px;
      background: var(--accent-soft);
      color: var(--accent);
      font-size: 0.87rem;
      font-weight: 600;
      text-align: center;
    }

    .main-tabs {
      margin-top: 4px;
    }

    .main-tabs > .tab-nav {
      gap: 10px;
      border-bottom: none !important;
      margin-bottom: 14px;
    }

    .main-tabs > .tab-nav button {
      border-radius: 999px !important;
      border: 1px solid rgba(47, 122, 83, 0.18) !important;
      background: rgba(255,255,255,0.72) !important;
      color: var(--body) !important;
      padding: 10px 18px !important;
      font-weight: 700 !important;
    }

    .main-tabs > .tab-nav button.selected {
      background: var(--accent) !important;
      color: white !important;
      border-color: var(--accent) !important;
    }

    .surface-card {
      border: 1px solid var(--card-border) !important;
      border-radius: 24px !important;
      background: var(--card-bg) !important;
      box-shadow: var(--shadow) !important;
      padding: 18px !important;
    }

    .workflow-grid {
      gap: 16px;
      align-items: stretch;
    }

    .step-card {
      border: 1px solid var(--card-border) !important;
      border-radius: 20px !important;
      padding: 18px !important;
      background: var(--card-strong) !important;
      box-shadow: 0 8px 24px rgba(33, 49, 42, 0.04) !important;
      margin: 0 0 14px !important;
    }

    .step-header {
      display: flex;
      gap: 12px;
      align-items: flex-start;
      margin-bottom: 14px;
    }

    .step-num {
      width: 32px;
      height: 32px;
      border-radius: 50%;
      background: var(--accent);
      color: white;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      font-weight: 700;
      font-size: 0.9rem;
      flex-shrink: 0;
      margin-top: 2px;
    }

    .step-title {
      display: block;
      color: var(--headline);
      font-size: 1.05rem;
      font-weight: 700;
      margin-bottom: 4px;
    }

    .step-desc {
      display: block;
      color: var(--muted);
      font-size: 0.87rem;
      line-height: 1.55;
    }

    .card-caption {
      color: var(--muted);
      font-size: 0.88rem;
      margin: -6px 0 10px;
    }

    .transcribe-spotlight {
      background: linear-gradient(135deg, rgba(47, 122, 83, 0.12), rgba(40, 98, 145, 0.08));
      border: 1px solid rgba(47, 122, 83, 0.14);
      border-radius: 18px;
      padding: 16px;
      margin-bottom: 14px;
    }

    .transcribe-spotlight strong {
      display: block;
      color: var(--headline);
      font-size: 1rem;
      margin-bottom: 4px;
    }

    .transcribe-spotlight span {
      display: block;
      color: var(--body);
      font-size: 0.9rem;
      line-height: 1.6;
    }

    .status-panel, .output-panel, .side-card {
      border: 1px solid var(--card-border) !important;
      border-radius: 20px !important;
      background: var(--card-strong) !important;
      box-shadow: 0 8px 24px rgba(33, 49, 42, 0.04) !important;
      padding: 18px !important;
      margin-bottom: 14px !important;
    }

    .panel-title {
      color: var(--headline);
      font-weight: 700;
      font-size: 1rem;
      margin-bottom: 10px;
    }

    .hint-list {
      display: grid;
      gap: 10px;
    }

    .hint-item {
      border-radius: 16px;
      padding: 14px 15px;
      background: rgba(47, 122, 83, 0.06);
      border: 1px solid rgba(47, 122, 83, 0.1);
    }

    .hint-item strong {
      display: block;
      color: var(--headline);
      margin-bottom: 4px;
      font-size: 0.94rem;
    }

    .hint-item span {
      color: var(--body);
      font-size: 0.88rem;
      line-height: 1.55;
    }

    .resource-links {
      display: grid;
      gap: 10px;
      margin-top: 12px;
    }

    .resource-link {
      display: block;
      text-decoration: none;
      color: var(--accent);
      background: rgba(47, 122, 83, 0.08);
      border: 1px solid rgba(47, 122, 83, 0.14);
      border-radius: 15px;
      padding: 13px 14px;
      font-weight: 700;
    }

    .resource-link small {
      display: block;
      color: var(--muted);
      font-weight: 500;
      margin-top: 4px;
      line-height: 1.5;
    }

    .settings-note {
      color: var(--muted);
      font-size: 0.9rem;
      margin-bottom: 14px;
    }

    .gradio-button.primary, .gradio-button.secondary {
      border-radius: 14px !important;
      font-weight: 700 !important;
    }

    @media (max-width: 1100px) {
      .hero-grid {
        grid-template-columns: 1fr;
      }
    }

    @media (max-width: 900px) {
      .workflow-grid {
        flex-direction: column !important;
      }

      .quick-facts {
        grid-template-columns: 1fr;
      }

      .gradio-container {
        padding: 14px 12px 22px !important;
      }

      .hero {
        padding: 22px 18px;
      }
    }
"""


def build_app() -> gr.Blocks:
    with gr.Blocks(title="かんたんボイスクローン for Qwen-TTS") as demo:
        prepared_reference_state = gr.State(value=None)

        with gr.Column(elem_classes=["app-shell"]):
            gr.HTML(
                """
                <section class="hero">
                  <div class="hero-grid">
                    <div>
                      <h1>かんたんボイスクローン</h1>
                      <p class="hero-lead">Qwen-TTS を日本語で迷わず使うための、初心者向けローカルアプリです。まずは左側で声の素材を整え、右側で文字と生成結果を確認してください。</p>
                      <div class="hero-note">このアプリは話者をなるべく寄せますが、完全に同じ声になるとは限りません。本人の声、または明確な許可がある声だけを使ってください。</div>
                    </div>
                    <div class="hero-side">
                      <div class="summary-card">
                        <div class="summary-title">最短 3 ステップ</div>
                        <div class="steps-overview">
                          <div class="step-line"><span class="step-badge">1</span><div><strong>素材を入れる</strong><span>音声か動画をアップロードして、必要なら前後を切ります。</span></div></div>
                          <div class="step-line"><span class="step-badge">2</span><div><strong>文字起こしを整える</strong><span>自動文字起こしを押して、内容が合っているかだけ確認します。</span></div></div>
                          <div class="step-line"><span class="step-badge">3</span><div><strong>読ませたい文章を生成</strong><span>短い文から試して、良ければそのまま保存します。</span></div></div>
                        </div>
                      </div>
                      <div class="summary-card">
                        <div class="summary-title">先に知っておくこと</div>
                        <div class="quick-facts">
                          <div class="fact-pill">参照音声は 3 秒以上</div>
                          <div class="fact-pill">最初は 1〜2 文で試す</div>
                          <div class="fact-pill">雑音が少ない素材が有利</div>
                          <div class="fact-pill">初回は少し時間がかかる</div>
                        </div>
                      </div>
                    </div>
                  </div>
                </section>
                """
            )

            with gr.Tabs(elem_classes=["main-tabs"]):
                with gr.Tab("音声生成"):
                    with gr.Group(elem_classes=["surface-card"]):
                        with gr.Row(elem_classes=["workflow-grid"]):
                            with gr.Column(scale=7, min_width=520):
                                with gr.Group(elem_classes=["step-card"]):
                                    gr.HTML(
                                        '<div class="step-header">'
                                        '<span class="step-num">1</span>'
                                        '<div><span class="step-title">参照音声を用意する</span>'
                                        '<span class="step-desc">音声でも動画でも OK です。必要なら前後だけ切ってから使えます。</span></div>'
                                        '</div>'
                                    )
                                    with gr.Row():
                                        reference_audio = gr.Audio(
                                            type="filepath",
                                            label="参照音声（アップロード / 録音）",
                                            sources=["upload", "microphone"],
                                        )
                                        reference_video = gr.Video(
                                            label="または参照動画",
                                            sources=["upload"],
                                            include_audio=True,
                                        )
                                    with gr.Row():
                                        trim_start_sec = gr.Number(
                                            label="開始位置（秒）",
                                            value=0,
                                            minimum=0,
                                            precision=1,
                                            info="先頭を飛ばしたいときだけ入力",
                                        )
                                        trim_end_sec = gr.Number(
                                            label="終了位置（秒）",
                                            value=0,
                                            minimum=0,
                                            precision=1,
                                            info="0 のままなら最後まで使います",
                                        )
                                        auto_trim_silence = gr.Checkbox(
                                            label="前後の無音を自動でカット",
                                            value=True,
                                        )
                                    prepare_button = gr.Button("素材を整えて確認する", variant="secondary")
                                    prepared_reference_audio = gr.Audio(
                                        type="filepath",
                                        label="整えた参照音声（確認用）",
                                        interactive=False,
                                    )

                                with gr.Group(elem_classes=["step-card"]):
                                    gr.HTML(
                                        '<div class="step-header">'
                                        '<span class="step-num">2</span>'
                                        '<div><span class="step-title">参照音声の文字起こしを確認する</span>'
                                        '<span class="step-desc">ここがズレると、声が別人っぽくなりやすいです。</span></div>'
                                        '</div>'
                                    )
                                    gr.HTML(
                                        '<div class="transcribe-spotlight">'
                                        '<strong>まずは「自動文字起こし」を押してください</strong>'
                                        '<span>参照音声の内容を下書きで入れます。内容が合っているか確認して、違っていたら少し直すだけで使えます。</span>'
                                        '</div>'
                                    )
                                    with gr.Row():
                                        transcription_backend = gr.Dropdown(
                                            label="文字起こし方式",
                                            choices=TRANSCRIBE_BACKENDS,
                                            value="自動選択",
                                            interactive=True,
                                        )
                                        transcribe_reference_button = gr.Button(
                                            "自動文字起こしする", variant="primary", size="lg"
                                        )
                                    reference_text = gr.Textbox(
                                        label="参照音声の文字起こし",
                                        placeholder="例: おはようございます。今日は少しだけ自己紹介をします。",
                                        lines=4,
                                        info="参照音声で実際に話している内容を、省略せずそのまま入れてください。",
                                    )
                                    fill_reference_text_button = gr.Button(
                                        "例文を入れて試す", size="sm", variant="secondary"
                                    )

                            with gr.Column(scale=5, min_width=400):
                                with gr.Group(elem_classes=["step-card"]):
                                    gr.HTML(
                                        '<div class="step-header">'
                                        '<span class="step-num">3</span>'
                                        '<div><span class="step-title">読ませたい文章を入れて生成する</span>'
                                        '<span class="step-desc">最初は短い文で確認すると失敗が少なく、結果も見やすいです。</span></div>'
                                        '</div>'
                                    )
                                    target_text = gr.Textbox(
                                        label="読ませたい文章",
                                        placeholder="例: こんにちは。これはボイスクローンのテストです。",
                                        lines=5,
                                        info="最初は 1〜2 文の短い文章から試してください。",
                                    )
                                    with gr.Row():
                                        target_language = gr.Dropdown(
                                            label="読み上げ言語",
                                            choices=SUPPORTED_LANGUAGES,
                                            value=DEFAULT_LANGUAGE_LABEL,
                                            interactive=True,
                                        )
                                        fill_target_text_button = gr.Button(
                                            "例文を入れて試す", size="sm", variant="secondary"
                                        )
                                    generate_button = gr.Button("音声を生成する", variant="primary", size="lg")

                                with gr.Group(elem_classes=["status-panel"]):
                                    gr.HTML('<div class="panel-title">現在の状況</div>')
                                    status = gr.Markdown(
                                        "左側で素材を整えたあと、\n"
                                        "1. 自動文字起こし\n"
                                        "2. 読ませたい文章を入力\n"
                                        "3. 音声を生成する\n"
                                        "の順に進めてください。**初回はモデル読み込みで 1〜2 分かかります。**"
                                    )

                                with gr.Group(elem_classes=["output-panel"]):
                                    gr.HTML('<div class="panel-title">生成結果</div>')
                                    output_audio = gr.Audio(
                                        type="filepath",
                                        label="生成した音声",
                                        interactive=False,
                                    )
                                    open_outputs_button = gr.Button("出力フォルダを開く", size="sm", variant="secondary")

                                with gr.Group(elem_classes=["side-card"]):
                                    gr.HTML(
                                        """
                                        <div class="panel-title">失敗しにくいコツ</div>
                                        <div class="hint-list">
                                          <div class="hint-item"><strong>声が別人っぽい</strong><span>参照音声の文字起こしが少しでもズレていないか確認してください。</span></div>
                                          <div class="hint-item"><strong>音が割れる・不安定</strong><span>雑音が少ない素材に変えて、まずは短い文章で試してください。</span></div>
                                          <div class="hint-item"><strong>文字起こしがうまく出ない</strong><span>別の素材にするか、文字起こし欄を手入力で直してください。</span></div>
                                        </div>
                                        """
                                    )

                with gr.Tab("設定"):
                    with gr.Group(elem_classes=["surface-card"]):
                        gr.HTML('<div class="panel-title">モデル設定</div>')
                        settings_summary = gr.Markdown(
                            build_settings_summary(), elem_classes=["settings-note"]
                        )
                        with gr.Row():
                            qwen_model_setting = gr.Dropdown(
                                label="Qwen-TTS モデル",
                                choices=list(QWEN_TTS_MODEL_CHOICES.keys()),
                                value=current_qwen_label(),
                                interactive=True,
                                info="高精度 1.7B は品質重視、軽量 0.6B は軽さ重視です。",
                            )
                            local_asr_setting = gr.Dropdown(
                                label="ローカル文字起こしモデル",
                                choices=LOCAL_ASR_MODEL_CHOICES,
                                value=APP_CONFIG.local_asr_model,
                                interactive=True,
                                info="small が標準です。base は軽く、medium は少し高精度です。",
                            )
                        save_settings_button = gr.Button("設定を保存する", variant="primary")
                        settings_status = gr.Markdown("ここで保存した設定は、次の生成から反映されます。")

                with gr.Tab("ヘルプ"):
                    with gr.Group(elem_classes=["surface-card"]):
                        gr.HTML(
                            """
                            <div class="panel-title">困ったときの見直しポイント</div>
                            <div class="hint-list">
                              <div class="hint-item"><strong>声が合わない</strong><span>参照音声の文字起こしを、聞こえた通りに 1 文字も省略せず入れてください。</span></div>
                              <div class="hint-item"><strong>動画を入れたら失敗する</strong><span>動画から音声を取り出すには ffmpeg が必要です。ターミナルなら <code>brew install ffmpeg</code> です。</span></div>
                              <div class="hint-item"><strong>生成が遅い</strong><span>初回はモデル読み込みに時間がかかります。再起動後も遅い場合は、まず 1 文だけで試してください。</span></div>
                              <div class="hint-item"><strong>ローカル文字起こしが使えない</strong><span>DMG 版ではセットアップ完了後に同梱環境が入ります。ソース版では <code>./install_local_asr.command</code> を実行してください。</span></div>
                            </div>
                            <div class="resource-links">
                              <a class="resource-link" href="https://github.com/kantaro4123/qwen-tts-jp-starter" target="_blank" rel="noopener noreferrer">GitHub レポジトリを見る<small>更新状況、README、リリース履歴を確認できます。</small></a>
                              <a class="resource-link" href="https://github.com/QwenLM/Qwen3-TTS" target="_blank" rel="noopener noreferrer">Qwen3-TTS 公式ページを見る<small>モデル本体の仕様や最新情報を確認したいときはこちらです。</small></a>
                            </div>
                            """
                        )

            prepare_button.click(
                fn=prepare_reference_audio,
                inputs=[reference_audio, reference_video, trim_start_sec, trim_end_sec, auto_trim_silence],
                outputs=[status, prepared_reference_audio, prepared_reference_state],
            )
            fill_reference_text_button.click(fn=fill_reference_text_example, outputs=[reference_text])
            transcribe_reference_button.click(
                fn=transcribe_reference_audio,
                inputs=[
                    reference_audio,
                    reference_video,
                    prepared_reference_state,
                    target_language,
                    transcription_backend,
                    trim_start_sec,
                    trim_end_sec,
                    auto_trim_silence,
                ],
                outputs=[status, prepared_reference_audio, prepared_reference_state, reference_text],
            )
            fill_target_text_button.click(fn=fill_target_text_example, outputs=[target_text])
            generate_button.click(
                fn=generate_voice_clone,
                inputs=[
                    reference_audio,
                    reference_video,
                    prepared_reference_state,
                    reference_text,
                    target_text,
                    target_language,
                    trim_start_sec,
                    trim_end_sec,
                    auto_trim_silence,
                ],
                outputs=[status, prepared_reference_audio, output_audio],
            )
            open_outputs_button.click(fn=open_output_folder, outputs=[status])
            save_settings_button.click(
                fn=save_model_settings,
                inputs=[qwen_model_setting, local_asr_setting],
                outputs=[settings_status],
            )
            save_settings_button.click(
                fn=build_settings_summary,
                outputs=[settings_summary],
            )

    return demo



if __name__ == "__main__":
    app = build_app()
    app.launch(server_name=APP_CONFIG.host, server_port=APP_CONFIG.port, css=CSS)
