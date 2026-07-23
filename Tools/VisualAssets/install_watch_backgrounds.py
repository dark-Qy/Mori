#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Install prepared scene PNGs into Watch assets.")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument(
        "--catalog",
        type=Path,
        default=Path("Design/WatchCompanionAssets/backgrounds/catalog.json"),
    )
    parser.add_argument(
        "--assets",
        type=Path,
        default=Path("Apps/Apple/WatchApp/Assets.xcassets/Scenes"),
    )
    return parser.parse_args()


def absolute(repo_root: Path, value: str | Path) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def image_set_contents(filename: str) -> dict:
    return {
        "images": [{"filename": filename, "idiom": "universal", "scale": "1x"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": False},
    }


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    catalog = json.loads(absolute(repo_root, args.catalog).read_text(encoding="utf-8"))
    assets = absolute(repo_root, args.assets)
    assets.mkdir(parents=True, exist_ok=True)
    (assets / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )

    installed = []
    for scene in catalog["backgrounds"]:
        for size in ("small", "large"):
            source = absolute(repo_root, scene[size])
            if not source.is_file():
                raise FileNotFoundError(f"{scene['id']}: missing prepared image {source}")
            asset_name = f"scene_{scene['id']}_{size}"
            image_set = assets / f"{asset_name}.imageset"
            image_set.mkdir(parents=True, exist_ok=True)
            filename = f"{asset_name}.png"
            shutil.copyfile(source, image_set / filename)
            (image_set / "Contents.json").write_text(
                json.dumps(image_set_contents(filename), indent=2) + "\n",
                encoding="utf-8",
            )
            installed.append(asset_name)

    print(json.dumps({"ok": True, "installed": installed}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
