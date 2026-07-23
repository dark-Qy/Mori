#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

from PIL import Image


EXPECTED_STATES = {
    "idle_neutral",
    "idle_resting",
    "idle_curious",
    "idle_lively",
    "touch_head",
    "touch_body",
    "action_success",
    "story_reaction",
}
EXPECTED_SOURCE_ROWS = {
    "idle",
    "running-right",
    "running-left",
    "waving",
    "jumping",
    "failed",
    "waiting",
    "running",
    "review",
}
ID_PATTERN = re.compile(r"^[a-z][a-z0-9_]*$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate Watch Companion visual assets.")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--allow-pending", action="store_true")
    parser.add_argument("--json-out", type=Path)
    return parser.parse_args()


def load_json(path: Path, errors: list[str]) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as error:
        errors.append(f"{path}: invalid JSON: {error}")
        return {}


def resolve(repo_root: Path, value: str | Path) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def check_image(
    path: Path,
    errors: list[str],
    *,
    size: tuple[int, int] | None = None,
    require_alpha: bool = False,
    require_opaque: bool = False,
) -> None:
    if not path.is_file():
        errors.append(f"missing image: {path}")
        return
    if path.suffix.lower() != ".png":
        errors.append(f"image must be PNG: {path}")
    try:
        with Image.open(path) as image:
            image.load()
            if image.format != "PNG":
                errors.append(f"not encoded as PNG: {path}")
            if size and image.size != size:
                errors.append(f"{path}: expected {size[0]}x{size[1]}, got {image.width}x{image.height}")
            has_alpha = "A" in image.getbands()
            if require_alpha and not has_alpha:
                errors.append(f"{path}: alpha channel is required")
            if require_opaque and has_alpha:
                extrema = image.getchannel("A").getextrema()
                if extrema != (255, 255):
                    errors.append(f"{path}: background must be fully opaque, alpha range is {extrema}")
    except Exception as error:
        errors.append(f"{path}: unreadable image: {error}")


def check_unit_rect(name: str, value: dict[str, Any], errors: list[str]) -> None:
    for key in ("x", "y", "width", "height"):
        item = value.get(key)
        if not isinstance(item, (int, float)) or not 0 <= item <= 1:
            errors.append(f"{name}.{key} must be within 0...1")
    if isinstance(value.get("x"), (int, float)) and isinstance(value.get("width"), (int, float)):
        if value["x"] + value["width"] > 1:
            errors.append(f"{name} extends beyond the right edge")
    if isinstance(value.get("y"), (int, float)) and isinstance(value.get("height"), (int, float)):
        if value["y"] + value["height"] > 1:
            errors.append(f"{name} extends beyond the bottom edge")


def validate_backgrounds(repo_root: Path, allow_pending: bool, errors: list[str]) -> dict[str, Any]:
    path = repo_root / "Design/WatchCompanionAssets/backgrounds/catalog.json"
    catalog = load_json(path, errors)
    backgrounds = catalog.get("backgrounds", [])
    if len(backgrounds) != 10:
        errors.append(f"{path}: expected exactly 10 backgrounds, got {len(backgrounds)}")
    ids = [item.get("id") for item in backgrounds if isinstance(item, dict)]
    if len(set(ids)) != len(ids):
        errors.append(f"{path}: duplicate background IDs")
    canvas = catalog.get("canvas", {})
    expected_sizes = {
        "master": (832, 1024),
        "small": (352, 430),
        "large": (416, 496),
    }
    for key, expected in expected_sizes.items():
        value = canvas.get(key, {})
        if (value.get("width"), value.get("height")) != expected:
            errors.append(f"{path}: canvas.{key} must be {expected[0]}x{expected[1]}")
    safe_regions = catalog.get("safeRegions", {})
    for name in ("top", "bottom"):
        check_unit_rect(f"safeRegions.{name}", safe_regions.get(name, {}), errors)
    slots = catalog.get("defaultSlots", {})
    if set(slots) != {"solo.center", "duo.left", "duo.right"}:
        errors.append(f"{path}: defaultSlots must contain solo.center, duo.left, duo.right")
    for name, slot in slots.items():
        for key in ("x", "footY"):
            value = slot.get(key)
            if not isinstance(value, (int, float)) or not 0 <= value <= 1:
                errors.append(f"{path}: slot {name}.{key} must be within 0...1")
        if not isinstance(slot.get("scale"), (int, float)) or slot["scale"] <= 0:
            errors.append(f"{path}: slot {name}.scale must be positive")

    ready = 0
    for scene in backgrounds:
        scene_id = scene.get("id", "<missing>")
        if not isinstance(scene_id, str) or not ID_PATTERN.match(scene_id):
            errors.append(f"{path}: invalid background ID {scene_id!r}")
        for field in ("displayName", "accessibilityDescription"):
            if not isinstance(scene.get(field), str) or not scene[field].strip():
                errors.append(f"{scene_id}: {field} is required")
        source_path = resolve(repo_root, scene.get("source", ""))
        check_image(source_path, errors, require_opaque=True)
        status = scene.get("status")
        if status == "ready":
            ready += 1
            for key, size in expected_sizes.items():
                check_image(resolve(repo_root, scene.get(key, "")), errors, size=size, require_opaque=True)
            foreground = scene.get("foreground")
            if foreground:
                check_image(
                    resolve(repo_root, foreground),
                    errors,
                    size=expected_sizes["master"],
                    require_alpha=True,
                )
        elif not allow_pending:
            errors.append(f"{scene_id}: background status is {status!r}, expected ready")
    return {"count": len(backgrounds), "ready": ready}


def validate_characters(repo_root: Path, allow_pending: bool, errors: list[str]) -> dict[str, Any]:
    path = repo_root / "Design/WatchCompanionAssets/characters/catalog.json"
    catalog = load_json(path, errors)
    if set(catalog.get("watchStates", [])) != EXPECTED_STATES:
        errors.append(f"{path}: watchStates do not match the required 8-state interface")
    cell = catalog.get("cell", {})
    if (cell.get("width"), cell.get("height")) != (192, 208):
        errors.append(f"{path}: cell must be 192x208")
    atlas = catalog.get("v2Atlas", {})
    expected_atlas = {
        "columns": 8,
        "rows": 11,
        "width": 1536,
        "height": 2288,
        "spriteVersionNumber": 2,
    }
    for key, expected in expected_atlas.items():
        if atlas.get(key) != expected:
            errors.append(f"{path}: v2Atlas.{key} must be {expected}")
    runtime = catalog.get("runtime", {})
    if runtime.get("maximumAtlasPageWidth", 0) > 1024:
        errors.append(f"{path}: runtime atlas page width exceeds 1024")
    if runtime.get("maximumAtlasPageHeight", 0) > 1024:
        errors.append(f"{path}: runtime atlas page height exceeds 1024")

    state_map_path = repo_root / "Design/WatchCompanionAssets/characters/runtime-state-map.json"
    state_map = load_json(state_map_path, errors)
    mapped_states = state_map.get("states", [])
    mapped_ids = {
        item.get("id") for item in mapped_states if isinstance(item, dict)
    }
    if mapped_ids != EXPECTED_STATES:
        errors.append(f"{state_map_path}: states do not match the required 8-state interface")
    if state_map.get("framesPerSecond") != runtime.get("framesPerSecond"):
        errors.append(f"{state_map_path}: framesPerSecond must match character runtime")
    if state_map.get("runtimeFrameCount") != 8:
        errors.append(f"{state_map_path}: runtimeFrameCount must be 8")
    for state in mapped_states:
        source_row = state.get("sourceRow")
        if source_row not in EXPECTED_SOURCE_ROWS:
            errors.append(f"{state_map_path}: invalid sourceRow {source_row!r}")
        reduce_motion_frame = state.get("reduceMotionFrame")
        if not isinstance(reduce_motion_frame, int) or not 0 <= reduce_motion_frame < 8:
            errors.append(
                f"{state_map_path}: {state.get('id')} reduceMotionFrame must be within 0...7"
            )

    characters = catalog.get("characters", [])
    if len(characters) != 2:
        errors.append(f"{path}: expected exactly 2 characters, got {len(characters)}")
    ids = [item.get("id") for item in characters if isinstance(item, dict)]
    if set(ids) != {"penguin", "polar_bear"}:
        errors.append(f"{path}: character IDs must be penguin and polar_bear")
    ready = 0
    for character in characters:
        character_id = character.get("id", "<missing>")
        check_image(resolve(repo_root, character.get("reference", "")), errors)
        run_dir = resolve(repo_root, character.get("runDirectory", ""))
        for required in ("pet_request.json", "imagegen-jobs.json"):
            if not (run_dir / required).is_file():
                errors.append(f"{character_id}: missing run file {run_dir / required}")
        status = character.get("status")
        if status == "ready":
            ready += 1
            check_image(
                resolve(repo_root, character.get("masterAtlas", "")),
                errors,
                size=(1536, 2288),
                require_alpha=True,
            )
            manifest_path = resolve(repo_root, character.get("packageManifest", ""))
            manifest = load_json(manifest_path, errors)
            if manifest.get("spriteVersionNumber") != 2:
                errors.append(f"{character_id}: package spriteVersionNumber must be 2")
            jobs = load_json(run_dir / "imagegen-jobs.json", errors).get("jobs", [])
            if len(jobs) != 13 or any(job.get("status") != "complete" for job in jobs):
                errors.append(f"{character_id}: all 13 generation jobs must be complete")
            required_json_evidence = (
                "qa/review.json",
                "qa/chroma-despill-extended.json",
                "qa/direction-semantics.json",
                "qa/direction-blind-validation.json",
                "qa/look-continuity.json",
                "final/validation-extended.json",
                "qa/run-summary.json",
            )
            for relative in required_json_evidence:
                evidence_path = run_dir / relative
                evidence = load_json(evidence_path, errors)
                if evidence.get("ok") is False:
                    errors.append(f"{character_id}: QA evidence failed: {evidence_path}")
            for relative in (
                "qa/contact-sheet-extended.png",
                "qa/look-directions.png",
                "qa/direction-blind-pairs.png",
            ):
                check_image(run_dir / relative, errors)
            for state in EXPECTED_SOURCE_ROWS:
                preview_path = run_dir / "qa/previews" / f"{state}.gif"
                if not preview_path.is_file():
                    errors.append(f"{character_id}: missing motion preview {preview_path}")
        elif not allow_pending:
            errors.append(f"{character_id}: character status is {status!r}, expected ready")
    return {"count": len(characters), "ready": ready}


def validate_runtime_exports(repo_root: Path, errors: list[str]) -> dict[str, Any]:
    background_catalog = load_json(
        repo_root / "Design/WatchCompanionAssets/backgrounds/catalog.json", errors
    )
    character_catalog = load_json(
        repo_root / "Design/WatchCompanionAssets/characters/catalog.json", errors
    )
    state_map = load_json(
        repo_root / "Design/WatchCompanionAssets/characters/runtime-state-map.json", errors
    )
    state_rows = {
        state.get("id"): state.get("sourceRow")
        for state in state_map.get("states", [])
        if isinstance(state, dict)
    }
    asset_roots = [
        repo_root / "Apps/Apple/WatchApp/Assets.xcassets",
        repo_root / "Apps/Apple/iPhoneApp/Assets.xcassets",
    ]
    background_exports = 0
    character_exports = 0
    for asset_root in asset_roots:
        for scene in background_catalog.get("backgrounds", []):
            for size_name, size in (("small", (352, 430)), ("large", (416, 496))):
                asset_name = f"scene_{scene['id']}_{size_name}"
                path = asset_root / "Scenes" / f"{asset_name}.imageset" / f"{asset_name}.png"
                check_image(path, errors, size=size, require_opaque=True)
                background_exports += 1
        for character in character_catalog.get("characters", []):
            for state in EXPECTED_STATES:
                row = state_rows.get(state)
                run_dir = resolve(repo_root, character.get("runDirectory", ""))
                source_frames = (
                    sorted((run_dir / "qa" / "rows" / str(row) / "frames" / str(row)).glob("*.png"))
                    if row
                    else []
                )
                if not source_frames:
                    errors.append(
                        f"{character['id']}: missing validated source frames for runtime state {state}"
                    )
                for index in range(8):
                    asset_name = f"character_{character['id']}_{state}_{index:02d}"
                    path = (
                        asset_root
                        / "Characters"
                        / f"{asset_name}.imageset"
                        / f"{asset_name}.png"
                    )
                    check_image(path, errors, size=(192, 208), require_alpha=True)
                    if source_frames:
                        expected = source_frames[index % len(source_frames)]
                        if path.is_file() and path.read_bytes() != expected.read_bytes():
                            errors.append(
                                f"{path}: does not match semantic source {expected}"
                            )
                    character_exports += 1
    return {
        "platforms": len(asset_roots),
        "backgroundImages": background_exports,
        "characterFrames": character_exports,
    }


def validate_scene_composites(repo_root: Path, errors: list[str]) -> dict[str, Any]:
    background_catalog = load_json(
        repo_root / "Design/WatchCompanionAssets/backgrounds/catalog.json", errors
    )
    qa_root = repo_root / "Design/WatchCompanionAssets/qa/composites"
    single_count = 0
    duo_count = 0
    for scene in background_catalog.get("backgrounds", []):
        for character_id in ("penguin", "polar_bear"):
            check_image(
                qa_root / "single" / f"{scene['id']}-{character_id}.png",
                errors,
                size=(416, 496),
                require_opaque=True,
            )
            single_count += 1
        check_image(
            qa_root / "duo" / f"{scene['id']}-duo.png",
            errors,
            size=(416, 496),
            require_opaque=True,
        )
        duo_count += 1
    check_image(qa_root / "single-contact-sheet.png", errors, require_opaque=True)
    check_image(qa_root / "duo-contact-sheet.png", errors, require_opaque=True)
    return {"single": single_count, "duo": duo_count}


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    errors: list[str] = []
    background_result = validate_backgrounds(repo_root, args.allow_pending, errors)
    character_result = validate_characters(repo_root, args.allow_pending, errors)
    runtime_result = validate_runtime_exports(repo_root, errors)
    composite_result = validate_scene_composites(repo_root, errors)
    result = {
        "ok": not errors,
        "allowPending": args.allow_pending,
        "backgrounds": background_result,
        "characters": character_result,
        "runtime": runtime_result,
        "composites": composite_result,
        "errors": errors,
    }
    output = json.dumps(result, ensure_ascii=False, indent=2)
    if args.json_out:
        output_path = resolve(repo_root, args.json_out)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(output + "\n", encoding="utf-8")
    print(output)
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
