from __future__ import annotations

import argparse
import json
from pathlib import Path


SETTINGS_PATH = Path(__file__).resolve().parent.parent / "config" / "settings.json"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qwen-model-id", required=True)
    parser.add_argument("--local-asr-model", required=True)
    args = parser.parse_args()

    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    settings = {
        "qwen_tts_model_id": args.qwen_model_id,
        "local_asr_model": args.local_asr_model,
    }
    SETTINGS_PATH.write_text(json.dumps(settings, ensure_ascii=False, indent=2), encoding="utf-8")
    print(SETTINGS_PATH)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
