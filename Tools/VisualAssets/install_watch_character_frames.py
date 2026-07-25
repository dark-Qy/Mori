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
        action="append",
        default=[],
        help=(
            "Asset catalog Characters directory. May be repeated. "
            "Defaults to both Watch and iPhone catalogs."
        ),
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


def runtime_frame_files(
    run_directory: Path,
    state: str,
    source_row: str,
    motion_statuses: dict[str, str],
) -> tuple[list[Path], str]:
    product_motion = (
        run_directory
        / "product-motion"
        / "frames"
        / state
    )
    product_frames = sorted(product_motion.glob("*.png"))
    motion_status = motion_statuses.get(state)
    if product_frames and motion_status in {None, "complete"}:
        return product_frames, f"product-motion/{state}"
    return frame_files(run_directory, source_row), source_row


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    catalog = json.loads(absolute(repo_root, args.catalog).read_text(encoding="utf-8"))
    state_map = json.loads(absolute(repo_root, args.state_map).read_text(encoding="utf-8"))
    state_rows = {state["id"]: state["sourceRow"] for state in state_map["states"]}
    frame_count = int(state_map["runtimeFrameCount"])
    asset_roots = [
        absolute(repo_root, path)
        for path in (
            args.assets
            or [
                Path("Apps/Apple/WatchApp/Assets.xcassets/Characters"),
                Path("Apps/Apple/iPhoneApp/Assets.xcassets/Characters"),
            ]
        )
    ]
    for assets in asset_roots:
        assets.mkdir(parents=True, exist_ok=True)
        (assets / "Contents.json").write_text(
            json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
            encoding="utf-8",
        )

    installed: dict[str, dict[str, str]] = {}
    for character in catalog["characters"]:
        character_id = character["id"]
        run_directory = absolute(repo_root, character["runDirectory"])
        is_basic_interaction = character.get("runtimeProfile") == "basic_interaction"
        installed[character_id] = {}
        idle_frames = frame_files(run_directory, "idle")
        if not idle_frames:
            raise FileNotFoundError(f"{character_id}: validated idle frames are required")
        motion_manifest_path = run_directory / "product-motion" / "manifest.json"
        motion_statuses: dict[str, str] = {}
        if motion_manifest_path.is_file():
            motion_manifest = json.loads(motion_manifest_path.read_text(encoding="utf-8"))
            motion_statuses = {
                job["id"]: job["status"]
                for job in motion_manifest.get("jobs", [])
                if isinstance(job, dict)
                and isinstance(job.get("id"), str)
                and isinstance(job.get("status"), str)
            }

        for state, row in state_rows.items():
            if is_basic_interaction and motion_statuses.get(state) != "complete":
                frames, source_row = idle_frames, "idle"
            else:
                frames, source_row = runtime_frame_files(
                    run_directory,
                    state,
                    row,
                    motion_statuses,
                )
            if not frames and args.allow_idle_fallback:
                frames = idle_frames
                source_row = "idle"
            if not frames:
                raise FileNotFoundError(f"{character_id}: missing validated {row} frames")

            installed[character_id][state] = source_row
            for index in range(frame_count):
                source = frames[index % len(frames)]
                asset_name = f"character_{character_id}_{state}_{index:02d}"
                for assets in asset_roots:
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
                "assetCatalogs": [str(path) for path in asset_roots],
                "installedSources": installed,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
