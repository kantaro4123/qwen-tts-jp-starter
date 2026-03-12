from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path


def sanitize_model_id(model_id: str) -> str:
    return model_id.replace("/", "--")


def copy_tree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--source-dir")
    args = parser.parse_args()

    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    bundle_dir = output_dir / sanitize_model_id(args.model_id)
    if args.source_dir:
        copy_tree(Path(args.source_dir).resolve(), bundle_dir)
    else:
        from huggingface_hub import snapshot_download

        snapshot_download(
            repo_id=args.model_id,
            local_dir=bundle_dir,
            local_dir_use_symlinks=False,
        )

    metadata_path = output_dir / "model-map.json"
    metadata = {}
    if metadata_path.exists():
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata[args.model_id] = bundle_dir.name
    metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    print(metadata_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
