#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path
from typing import Any


ASSET_ROOTS = (
    Path("Apps/Apple/WatchApp/Assets.xcassets/Characters"),
    Path("Apps/Apple/iPhoneApp/Assets.xcassets/Characters"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Install finalized Mori product-motion frames into Apple asset catalogs."
    )
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument(
        "--character",
        action="append",
        choices=("penguin", "polar_bear"),
        help="Install one character; repeat for both. Defaults to both.",
    )
    return parser.parse_args()


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def contents(filename: str) -> dict[str, Any]:
    return {
        "images": [{"filename": filename, "idiom": "universal", "scale": "1x"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": False},
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    character_ids = tuple(args.character or ("penguin", "polar_bear"))
    receipts: list[dict[str, Any]] = []

    for character_id in character_ids:
        product_root = (
            repo_root
            / "Design/WatchCompanionAssets/characters"
            / f"{character_id}-v2"
            / "product-motion"
        )
        validation = read_json(product_root / "final" / "validation.json")
        manifest = read_json(product_root / "final" / "motion-manifest.json")
        if validation.get("ok") is not True or manifest.get("status") != "ready":
            raise ValueError(f"{character_id}: product-motion package is not finalized")
        if manifest.get("characterID") != character_id:
            raise ValueError(f"{character_id}: final manifest character mismatch")

        installed: list[dict[str, Any]] = []
        for asset_root_relative in ASSET_ROOTS:
            asset_root = repo_root / asset_root_relative
            asset_root.mkdir(parents=True, exist_ok=True)
            contents_path = asset_root / "Contents.json"
            if not contents_path.exists():
                contents_path.write_text(
                    json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
                    encoding="utf-8",
                )
            for motion in manifest["motions"]:
                frame_paths = [repo_root / value for value in motion["frames"]]
                asset_names = motion["assetNames"]
                if len(frame_paths) != len(asset_names):
                    raise ValueError(f"{character_id}/{motion['id']}: frame/name count mismatch")
                for source, asset_name in zip(frame_paths, asset_names):
                    if not source.is_file():
                        raise FileNotFoundError(source)
                    image_set = asset_root / f"{asset_name}.imageset"
                    image_set.mkdir(parents=True, exist_ok=True)
                    filename = f"{asset_name}.png"
                    destination = image_set / filename
                    shutil.copyfile(source, destination)
                    (image_set / "Contents.json").write_text(
                        json.dumps(contents(filename), indent=2) + "\n",
                        encoding="utf-8",
                    )
                    installed.append(
                        {
                            "catalog": str(asset_root_relative),
                            "assetName": asset_name,
                            "source": str(source.relative_to(repo_root)),
                            "sha256": sha256(destination),
                        }
                    )

        receipt = {
            "schemaVersion": 1,
            "characterID": character_id,
            "catalogCount": len(ASSET_ROOTS),
            "motionCount": len(manifest["motions"]),
            "frameCount": len(installed),
            "installed": installed,
        }
        receipt_path = product_root / "final" / "install-receipt.json"
        receipt_path.write_text(
            json.dumps(receipt, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        receipts.append(
            {
                "characterID": character_id,
                "motionCount": receipt["motionCount"],
                "frameCount": receipt["frameCount"],
                "receipt": str(receipt_path.relative_to(repo_root)),
            }
        )

    print(json.dumps({"ok": True, "characters": receipts}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
