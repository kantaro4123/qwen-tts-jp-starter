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
TRANSCRIBE_CLI = Path(os.environ.get("TRANSCRIBE_CLI", str(Path.home() / ".codex/skills/transcribe/scripts/transcribe_diarize.py")))
LOCAL_ASR_MODEL = os.environ.get("QWEN_TTS_LOCAL_ASR_MODEL", "small")
SETTINGS_PATH = Path("config/settings.json")
QWEN_TTS_MODEL_CHOICES = {
    "高精度 1.7B": "Qwen/Qwen3-TTS-12Hz-1.7B-Base",
    "軽量 0.6B": "Qwen/Qwen3-TTS-12Hz-0.6B-Base",
}
LOCAL_ASR_MODEL_CHOICES = ["base", "small", "medium"]
SUPPORTED_LANGUAGES = [
    "Auto",
    "Chinese",
    "English",
    "German",
    "Italian",
    "Portuguese",
    "Spanish",
    "Japanese",
    "Korean",
    "French",
    "Russian",
]
DEFAULT_OUTPUT_DIR = Path("outputs")
DEFAULT_REFERENCE_DIR = DEFAULT_OUTPUT_DIR / "references"
DEFAULT_GENERATED_DIR = DEFAULT_OUTPUT_DIR / "generated"
DEFAULT_GENERATION_KWARGS = {}
TARGET_REFERENCE_SAMPLE_RATE = 24000
TARGET_REFERENCE_DBFS = -20.0
TRANSCRIBE_BACKENDS = ["自動選択", "OpenAI API", "ローカル faster-whisper"]
TRANSCRIBE_LANGUAGE_HINTS = {
    "Auto": "",
    "Chinese": "zh",
    "English": "en",
    "German": "de",
    "Italian": "it",
    "Portuguese": "pt",
    "Spanish": "es",
    "Japanese": "ja",
    "Korean": "ko",
    "French": "fr",
    "Russian": "ru",
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
        if Path(local_path).exists():
            result[model_id] = local_path
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

    backend_label = transcription_backend_selector
    if backend_label == "自動選択":
        if os.environ.get("OPENAI_API_KEY") and TRANSCRIBE_CLI.exists():
            backend_label = "OpenAI API"
        else:
            backend_label = "ローカル faster-whisper"

    language_hint = TRANSCRIBE_LANGUAGE_HINTS.get(target_language, "")

    if backend_label == "OpenAI API":
        if not os.environ.get("OPENAI_API_KEY"):
            return (
                "OpenAI API での自動文字起こしには `OPENAI_API_KEY` が必要です。",
                resolved_reference_audio,
                resolved_reference_audio,
                "",
            )
        if not TRANSCRIBE_CLI.exists():
            return (
                f"文字起こしスクリプトが見つかりませんでした: {TRANSCRIBE_CLI}",
                resolved_reference_audio,
                resolved_reference_audio,
                "",
            )
        cmd = [
            "python3",
            str(TRANSCRIBE_CLI),
            resolved_reference_audio,
            "--response-format",
            "text",
            "--stdout",
        ]
        if language_hint:
            cmd.extend(["--language", language_hint])
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            error_text = (result.stderr or result.stdout or "unknown error").strip()
            return (
                f"自動文字起こしに失敗しました: {error_text}",
                resolved_reference_audio,
                resolved_reference_audio,
                "",
            )
        transcript = result.stdout.strip()
        backend_status = "OpenAI API"
    else:
        try:
            from faster_whisper import WhisperModel
        except Exception:
            return (
                "ローカル faster-whisper が未インストールです。`./install_local_asr.command` を実行してください。",
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
        language=target_language or DEFAULT_LANGUAGE,
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
      --page-bg: linear-gradient(135deg, #f6efe7 0%, #f2f8f2 55%, #eef6ff 100%);
      --card-bg: rgba(255, 255, 255, 0.86);
      --card-border: rgba(57, 88, 74, 0.12);
      --headline: #1e2c25;
      --body: #33423b;
      --accent: #2b6a4a;
      --accent-2: #cb6b3d;
    }

    .app-shell {
      max-width: 980px;
      margin: 0 auto;
    }

    .hero {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 24px;
      padding: 28px;
      box-shadow: 0 24px 60px rgba(40, 62, 51, 0.08);
    }

    .hero h1 {
      color: var(--headline);
      font-size: 2.2rem;
      margin-bottom: 8px;
    }

    .hero p, .hero li {
      color: var(--body);
      line-height: 1.7;
    }

    .tip {
      border-left: 4px solid var(--accent-2);
      padding-left: 14px;
      margin-top: 12px;
    }
    """

def build_app() -> gr.Blocks:
    with gr.Blocks(title="かんたんボイスクローン for Qwen-TTS") as demo:
        with gr.Column(elem_classes=["app-shell"]):
            gr.HTML(
                """
                <section class="hero">
                  <h1>かんたんボイスクローン</h1>
                  <p>Qwen-TTS を日本語でわかりやすく使うための、初心者向けローカルアプリです。</p>
                  <ol>
                    <li>音声または動画を入れて、必要なら切り出す</li>
                    <li>その音声の文字起こしを正確に入力する</li>
                    <li>読ませたい文章を入れて生成する</li>
                  </ol>
                  <p class="tip">このアプリは話者をなるべく寄せますが、完全に同一の声になるとは限りません。本人の声、または明確な許可がある声だけを使ってください。</p>
                </section>
                """
            )

            prepared_reference_state = gr.State(value=None)

            with gr.Row():
                reference_audio = gr.Audio(
                    type="filepath",
                    label="1. 参照音声",
                    sources=["upload", "microphone"],
                )
                reference_video = gr.Video(
                    label="参考用の動画でもOK",
                    sources=["upload"],
                    include_audio=True,
                )

            with gr.Row():
                trim_start_sec = gr.Number(label="切り出し開始秒", value=0, minimum=0, precision=1)
                trim_end_sec = gr.Number(label="切り出し終了秒", value=0, minimum=0, precision=1)
                auto_trim_silence = gr.Checkbox(label="前後の無音を自動でカット", value=True)

            prepared_reference_audio = gr.Audio(
                type="filepath",
                label="整えた参照音声",
                interactive=False,
            )

            reference_text = gr.Textbox(
                label="2. 参照音声の文字起こし",
                placeholder="例: おはようございます。今日は少しだけ自己紹介をします。",
                lines=3,
            )
            fill_reference_text_button = gr.Button("参照テキストの例文を入れる")
            transcribe_reference_button = gr.Button("参照音声を自動文字起こし")

            target_text = gr.Textbox(
                label="3. 読ませたい文章",
                placeholder="例: こんにちは。これはボイスクローンのテストです。",
                lines=4,
            )
            fill_target_text_button = gr.Button("読ませたい文章の例文を入れる")
            target_language = gr.Dropdown(
                label="4. 読ませる言語",
                choices=SUPPORTED_LANGUAGES,
                value=DEFAULT_LANGUAGE,
                interactive=True,
            )
            transcription_backend = gr.Dropdown(
                label="参照音声の文字起こし方式",
                choices=TRANSCRIBE_BACKENDS,
                value="自動選択",
                interactive=True,
            )

            status = gr.Markdown(
                "先に「参照素材を整える」で切り出し結果を確認できます。初回の音声生成はモデルの読み込みに少し時間がかかります。"
            )

            output_audio = gr.Audio(
                type="filepath",
                label="5. 生成結果",
                interactive=False,
            )

            with gr.Accordion("設定", open=False):
                settings_summary = gr.Markdown(build_settings_summary())
                qwen_model_setting = gr.Dropdown(
                    label="Qwen-TTS モデル",
                    choices=list(QWEN_TTS_MODEL_CHOICES.keys()),
                    value=current_qwen_label(),
                    interactive=True,
                )
                local_asr_setting = gr.Dropdown(
                    label="ローカル faster-whisper モデル",
                    choices=LOCAL_ASR_MODEL_CHOICES,
                    value=APP_CONFIG.local_asr_model,
                    interactive=True,
                )
                save_settings_button = gr.Button("設定を保存")
                save_settings_button.click(
                    fn=save_model_settings,
                    inputs=[qwen_model_setting, local_asr_setting],
                    outputs=[status],
                )
                save_settings_button.click(
                    fn=build_settings_summary,
                    outputs=[settings_summary],
                )

            prepare_button = gr.Button("参照素材を整える")
            generate_button = gr.Button("音声生成", variant="primary")

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
            open_outputs_button = gr.Button("出力フォルダを開く")
            open_outputs_button.click(fn=open_output_folder, outputs=[status])

            gr.Markdown(
                """
                ### うまくいかないとき
                - 動画を入れた場合は、音声を自動で取り出して参照音声に変換します。
                - 先に「参照素材を整える」を押すと、切り出し結果を確認できます。
                - 声が不安定なときは、雑音の少ない3秒以上の音声を使ってください。精度を上げたいなら30秒前後も有効です。
                - 参照音声と参照テキストが少しでもズレると、別人っぽい声になりやすいです。
                - 生成が極端に遅いときは、一度アプリを再起動してから短文で試してください。
                - 参照素材は保存前にモノラル化・24kHz化・軽い音量調整を行っています。
                - 参照テキストは、省略せずに実際の音声どおり入力してください。
                - 最初は短い文で試すと成功しやすいです。
                """
            )

    return demo


if __name__ == "__main__":
    app = build_app()
    app.launch(server_name=APP_CONFIG.host, server_port=APP_CONFIG.port, css=CSS)
