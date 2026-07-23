#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Install normalized Watch character frame assets.")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument(
        "--catalog",
        type=Path,
        default=Path("Design/WatchCompanionAssets/characters/catalog.json"),
    )
    parser.add_argument(
        "--assets",
        type=Path,
        default=Path("Apps/Apple/WatchApp/Assets.xcassets/Characters"),
    )
    parser.add_argument(
        "--state-map",
        type=Path,
        default=Path("Design/WatchCompanionAssets/characters/runtime-state-map.json"),
    )
    parser.add_argument(
        "--allow-idle-fallback",
        action="store_true",
        help="Use the validated idle row while a semantic action row is still pending.",
    )
    return parser.parse_args()


def absolute(repo_root: Path, value: str | Path) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def contents(filename: str) -> dict:
    return {
        "images": [{"filename": filename, "idiom": "universal", "scale": "1x"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": False},
    }


def frame_files(run_directory: Path, row: str) -> list[Path]:
    directory = run_directory / "qa" / "rows" / row / "frames" / row
    return sorted(directory.glob("*.png"))


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    catalog = json.loads(absolute(repo_root, args.catalog).read_text(encoding="utf-8"))
    state_map = json.loads(absolute(repo_root, args.state_map).read_text(encoding="utf-8"))
    state_rows = {state["id"]: state["sourceRow"] for state in state_map["states"]}
    frame_count = int(state_map["runtimeFrameCount"])
    assets = absolute(repo_root, args.assets)
    assets.mkdir(parents=True, exist_ok=True)
    (assets / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )

    installed: dict[str, dict[str, str]] = {}
    for character in catalog["characters"]:
        character_id = character["id"]
        run_directory = absolute(repo_root, character["runDirectory"])
        installed[character_id] = {}
        idle_frames = frame_files(run_directory, "idle")
        if not idle_frames:
            raise FileNotFoundError(f"{character_id}: validated idle frames are required")

        for state, row in state_rows.items():
            frames = frame_files(run_directory, row)
            source_row = row
            if not frames and args.allow_idle_fallback:
                frames = idle_frames
                source_row = "idle"
            if not frames:
                raise FileNotFoundError(f"{character_id}: missing validated {row} frames")

            installed[character_id][state] = source_row
            for index in range(frame_count):
                source = frames[index % len(frames)]
                asset_name = f"character_{character_id}_{state}_{index:02d}"
                image_set = assets / f"{asset_name}.imageset"
                image_set.mkdir(parents=True, exist_ok=True)
                filename = f"{asset_name}.png"
                shutil.copyfile(source, image_set / filename)
                (image_set / "Contents.json").write_text(
                    json.dumps(contents(filename), indent=2) + "\n",
                    encoding="utf-8",
                )

    print(
        json.dumps(
            {
                "ok": True,
                "framesPerState": frame_count,
                "installedSources": installed,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
