from __future__ import annotations

import shutil
from pathlib import Path


def remove_path(path: Path) -> int:
    if not path.exists():
        return 0
    if path.is_dir():
        size = sum(f.stat().st_size for f in path.rglob('*') if f.is_file())
        shutil.rmtree(path, ignore_errors=True)
        return size
    size = path.stat().st_size
    path.unlink(missing_ok=True)
    return size


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description='Prune non-runtime files from the standalone bundle.')
    parser.add_argument('runtime_root', type=Path)
    args = parser.parse_args()

    root = args.runtime_root.resolve()
    removed_bytes = 0

    # Remove caches and installer-only tooling from the shipped runtime.
    for path in list(root.rglob('__pycache__')):
        removed_bytes += remove_path(path)
    for path in list(root.rglob('*.pyc')):
        removed_bytes += remove_path(path)
    for path in list(root.rglob('.DS_Store')):
        removed_bytes += remove_path(path)

    for lib_root in root.glob('.venv/lib/python*'):
        removed_bytes += remove_path(lib_root / 'ensurepip')
        site_packages = lib_root / 'site-packages'
        if not site_packages.exists():
            continue
        for name in [
            'pip',
            'pip-25.3.dist-info',
            'pip-24.0.dist-info',
            'pip-23.0.dist-info',
            'wheel',
            'wheel-0.45.1.dist-info',
            'wheel-0.43.0.dist-info',
            'wheel-0.42.0.dist-info',
        ]:
            removed_bytes += remove_path(site_packages / name)

    print(f'Pruned standalone runtime: {removed_bytes / 1024 / 1024:.1f} MiB removed')


if __name__ == '__main__':
    main()
