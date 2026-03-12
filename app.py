from __future__ import annotations

import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import gradio as gr
import soundfile as sf
import torch
from qwen_tts import Qwen3TTSModel


DEFAULT_MODEL_ID = "Qwen/Qwen3-TTS-12Hz-1.7B-Base"
DEFAULT_LANGUAGE = "Japanese"
DEFAULT_OUTPUT_DIR = Path("outputs")


@dataclass
class AppConfig:
    model_id: str = os.environ.get("QWEN_TTS_MODEL_ID", DEFAULT_MODEL_ID)
    host: str = os.environ.get("QWEN_TTS_HOST", "127.0.0.1")
    port: int = int(os.environ.get("QWEN_TTS_PORT", "7860"))
    output_dir: Path = Path(os.environ.get("QWEN_TTS_OUTPUT_DIR", str(DEFAULT_OUTPUT_DIR)))


APP_CONFIG = AppConfig()
_MODEL: Optional[Qwen3TTSModel] = None


def detect_device() -> str:
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def load_model() -> Qwen3TTSModel:
    global _MODEL
    if _MODEL is not None:
        return _MODEL

    device = detect_device()
    model = Qwen3TTSModel.from_pretrained(
        APP_CONFIG.model_id,
        device_map=device,
        dtype=torch.float32,
        attn_implementation="eager",
    )
    _MODEL = model
    return model


def validate_inputs(reference_audio: Optional[str], reference_text: str, target_text: str) -> Optional[str]:
    if not reference_audio:
        return "参照音声をアップロードしてください。"
    if not reference_text.strip():
        return "参照音声で実際に話している内容を、参照テキストに入力してください。"
    if not target_text.strip():
        return "読ませたい文章を入力してください。"
    return None


def save_output_audio(waveform, sample_rate: int) -> str:
    APP_CONFIG.output_dir.mkdir(parents=True, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(prefix="qwen-tts-jp-", suffix=".wav", dir=APP_CONFIG.output_dir)
    os.close(fd)
    sf.write(temp_path, waveform, sample_rate)
    return temp_path


def generate_voice_clone(reference_audio: Optional[str], reference_text: str, target_text: str) -> tuple[str, Optional[str]]:
    error = validate_inputs(reference_audio, reference_text, target_text)
    if error:
        return error, None

    model = load_model()
    wavs, sample_rate = model.generate_voice_clone(
        text=target_text.strip(),
        language=DEFAULT_LANGUAGE,
        ref_audio=reference_audio,
        ref_text=reference_text.strip(),
        non_streaming_mode=True,
    )
    output_path = save_output_audio(wavs[0], sample_rate)
    message = (
        "生成できました。下のプレイヤーで確認して、必要なら wav ファイルとして保存してください。"
    )
    return message, output_path


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
                    <li>3〜10秒くらいの参照音声を入れる</li>
                    <li>その音声の文字起こしを正確に入力する</li>
                    <li>読ませたい文章を入れて生成する</li>
                  </ol>
                  <p class="tip">本人の声、または明確な許可がある声だけを使ってください。なりすましや迷惑行為への利用は避けてください。</p>
                </section>
                """
            )

            with gr.Row():
                reference_audio = gr.Audio(
                    type="filepath",
                    label="1. 参照音声",
                    sources=["upload", "microphone"],
                )
                output_audio = gr.Audio(
                    type="filepath",
                    label="4. 生成結果",
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
                "「音声生成」を押すと、初回はモデルの読み込みに少し時間がかかります。"
            )

            generate_button = gr.Button("音声生成", variant="primary")
            generate_button.click(
                fn=generate_voice_clone,
                inputs=[reference_audio, reference_text, target_text],
                outputs=[status, output_audio],
            )

            gr.Markdown(
                """
                ### うまくいかないとき
                - 声が不安定なときは、雑音の少ない3〜10秒の音声を使ってください。
                - 参照テキストは、省略せずに実際の音声どおり入力してください。
                - 最初は短い文で試すと成功しやすいです。
                """
            )

    return demo


if __name__ == "__main__":
    app = build_app()
    app.launch(server_name=APP_CONFIG.host, server_port=APP_CONFIG.port, css=CSS)
