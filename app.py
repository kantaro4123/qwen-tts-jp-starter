from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import gradio as gr
import soundfile as sf
import torch
from pydub import AudioSegment
from pydub.silence import detect_nonsilent
from qwen_tts import Qwen3TTSModel


DEFAULT_MODEL_ID = "Qwen/Qwen3-TTS-12Hz-0.6B-Base"
DEFAULT_LANGUAGE = "Japanese"
DEFAULT_OUTPUT_DIR = Path("outputs")
DEFAULT_REFERENCE_DIR = DEFAULT_OUTPUT_DIR / "references"
DEFAULT_GENERATED_DIR = DEFAULT_OUTPUT_DIR / "generated"
DEFAULT_GENERATION_KWARGS = {
    "do_sample": False,
    "subtalker_dosample": False,
    "repetition_penalty": 1.05,
}


@dataclass
class AppConfig:
    model_id: str = os.environ.get("QWEN_TTS_MODEL_ID", DEFAULT_MODEL_ID)
    host: str = os.environ.get("QWEN_TTS_HOST", "127.0.0.1")
    port: int = int(os.environ.get("QWEN_TTS_PORT", "7860"))
    output_dir: Path = Path(os.environ.get("QWEN_TTS_OUTPUT_DIR", str(DEFAULT_OUTPUT_DIR)))


APP_CONFIG = AppConfig()
_MODEL: Optional[Qwen3TTSModel] = None
_MODEL_ID_LOADED: Optional[str] = None
_VOICE_PROMPT_CACHE: dict[tuple[str, str, int], object] = {}


def detect_device() -> str:
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def load_model() -> Qwen3TTSModel:
    global _MODEL, _MODEL_ID_LOADED
    if _MODEL is not None and _MODEL_ID_LOADED == APP_CONFIG.model_id:
        return _MODEL

    device = detect_device()
    model = Qwen3TTSModel.from_pretrained(
        APP_CONFIG.model_id,
        device_map=device,
        dtype=torch.float32,
        attn_implementation="eager",
    )
    _MODEL = model
    _MODEL_ID_LOADED = APP_CONFIG.model_id
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

    if len(prepared) == 0:
        raise ValueError("切り出した結果が空になりました。切り出し範囲を見直してください。")

    output_path = save_reference_audio(prepared)
    duration_sec = len(prepared) / 1000
    status = f"参照素材を整えました。元の入力: {source_label} / 長さ: {duration_sec:.1f}秒"
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


def estimate_max_new_tokens(target_text: str) -> int:
    text_length = len(target_text.strip())
    return max(180, min(900, text_length * 18))


def get_voice_prompt_cache_key(reference_audio: str, reference_text: str) -> tuple[str, str, int]:
    ref_path = Path(reference_audio)
    stat = ref_path.stat()
    return (str(ref_path.resolve()), reference_text.strip(), stat.st_mtime_ns)


def get_or_create_voice_prompt(model: Qwen3TTSModel, reference_audio: str, reference_text: str):
    cache_key = get_voice_prompt_cache_key(reference_audio, reference_text)
    cached = _VOICE_PROMPT_CACHE.get(cache_key)
    if cached is not None:
        return cached, True

    prompt = model.create_voice_clone_prompt(
        ref_audio=reference_audio,
        ref_text=reference_text.strip(),
        x_vector_only_mode=False,
    )
    _VOICE_PROMPT_CACHE[cache_key] = prompt
    return prompt, False


def generate_voice_clone(
    reference_audio: Optional[str],
    reference_video: Optional[str],
    prepared_reference_audio: Optional[str],
    reference_text: str,
    target_text: str,
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

    if len(target_text.strip()) > 80:
        return "まずは短文で試してください。現在の高速設定では、80文字以下くらいが安定です。", resolved_reference_audio, None

    model = load_model()
    start_time = time.time()
    prompt_items, cache_hit = get_or_create_voice_prompt(model, resolved_reference_audio, reference_text)
    prompt_elapsed = time.time() - start_time
    generation_start = time.time()
    max_new_tokens = estimate_max_new_tokens(target_text)
    wavs, sample_rate = model.generate_voice_clone(
        text=target_text.strip(),
        language=DEFAULT_LANGUAGE,
        voice_clone_prompt=prompt_items,
        non_streaming_mode=True,
        max_new_tokens=max_new_tokens,
        **DEFAULT_GENERATION_KWARGS,
    )
    generation_elapsed = time.time() - generation_start
    output_path = save_output_audio(wavs[0], sample_rate)
    message = (
        "生成できました。"
        f" 参照音声の準備: {prompt_elapsed:.1f}秒"
        f" / 音声生成: {generation_elapsed:.1f}秒"
        f" / 話者キャッシュ: {'再利用' if cache_hit else '新規作成'}"
        f" / max_new_tokens: {max_new_tokens}"
    )
    return message, resolved_reference_audio, output_path


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
                  <p>Qwen-TTS を日本語でわかりやすく使うための、初心者向けローカルアプリです。既定では速度優先の 0.6B モデルを使います。</p>
                  <ol>
                    <li>音声または動画を入れて、必要なら切り出す</li>
                    <li>その音声の文字起こしを正確に入力する</li>
                    <li>読ませたい文章を入れて生成する</li>
                  </ol>
                  <p class="tip">このアプリは話者をなるべく寄せますが、完全に同一の声になるとは限りません。まずは短文で確認してください。本人の声、または明確な許可がある声だけを使ってください。</p>
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

            target_text = gr.Textbox(
                label="3. 読ませたい文章",
                placeholder="例: こんにちは。これはボイスクローンのテストです。",
                lines=4,
            )

            status = gr.Markdown(
                "先に「参照素材を整える」で切り出し結果を確認できます。初回の音声生成はモデルの読み込みに少し時間がかかります。"
            )

            output_audio = gr.Audio(
                type="filepath",
                label="4. 生成結果",
                interactive=False,
            )

            prepare_button = gr.Button("参照素材を整える")
            generate_button = gr.Button("音声生成", variant="primary")

            prepare_button.click(
                fn=prepare_reference_audio,
                inputs=[reference_audio, reference_video, trim_start_sec, trim_end_sec, auto_trim_silence],
                outputs=[status, prepared_reference_audio, prepared_reference_state],
            )
            generate_button.click(
                fn=generate_voice_clone,
                inputs=[
                    reference_audio,
                    reference_video,
                    prepared_reference_state,
                    reference_text,
                    target_text,
                    trim_start_sec,
                    trim_end_sec,
                    auto_trim_silence,
                ],
                outputs=[status, prepared_reference_audio, output_audio],
            )

            gr.Markdown(
                """
                ### うまくいかないとき
                - 動画を入れた場合は、音声を自動で取り出して参照音声に変換します。
                - 先に「参照素材を整える」を押すと、切り出し結果を確認できます。
                - 声が不安定なときは、雑音の少ない3秒以上の音声を使ってください。精度を上げたいなら30秒前後も有効です。
                - 参照音声と参照テキストが少しでもズレると、別人っぽい声になりやすいです。
                - このアプリは速度優先の 0.6B モデルを既定で使い、話者プロンプトも再利用して遅さを抑えています。
                - 参照テキストは、省略せずに実際の音声どおり入力してください。
                - 最初は短い文で試すと成功しやすいです。長文は時間がかかります。
                """
            )

    return demo


if __name__ == "__main__":
    app = build_app()
    app.launch(server_name=APP_CONFIG.host, server_port=APP_CONFIG.port, css=CSS)
