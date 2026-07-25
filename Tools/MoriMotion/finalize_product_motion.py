#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont


CELL_SIZE = (192, 208)
FRAME_COUNT = 8
MOTION_ORDER = (
    "idle_neutral",
    "idle_resting",
    "idle_curious",
    "idle_lively",
    "touch_head",
    "touch_body",
    "walk",
    "brisk_move",
    "sit_down",
    "catch_breath",
    "route_reflection",
    "speaking",
    "action_success",
    "story_reaction",
    "daily_reflection",
    "bedtime",
)
CANONICAL_ROWS = (
    "idle",
    "running-right",
    "running-left",
    "waving",
    "jumping",
    "failed",
    "waiting",
    "running",
    "review",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Finalize one character's validated Mori product-motion package."
    )
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--character", required=True, choices=("penguin", "polar_bear"))
    return parser.parse_args()


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sequence_sha256(paths: list[Path]) -> str:
    digest = hashlib.sha256()
    for path in paths:
        digest.update(path.name.encode("utf-8"))
        digest.update(path.read_bytes())
    return digest.hexdigest()


def standard_row_frames(character_root: Path, row: str) -> list[Path]:
    paths = sorted((character_root / "qa" / "rows" / row / "frames" / row).glob("*.png"))
    if not paths:
        raise FileNotFoundError(f"missing approved hatch-pet row: {row}")
    return [paths[index % len(paths)] for index in range(FRAME_COUNT)]


def product_frames(product_root: Path, motion_id: str) -> list[Path]:
    paths = sorted((product_root / "frames" / motion_id).glob("*.png"))
    if len(paths) != FRAME_COUNT:
        raise FileNotFoundError(
            f"{motion_id} needs {FRAME_COUNT} validated frames, found {len(paths)}"
        )
    return paths


def alpha_edge_count(image: Image.Image, margin: int = 2) -> int:
    alpha = image.getchannel("A")
    width, height = alpha.size
    return sum(
        sum(alpha.crop(box).histogram()[1:])
        for box in (
            (0, 0, width, margin),
            (0, height - margin, width, height),
            (0, 0, margin, height),
            (width - margin, 0, width, height),
        )
    )


def validate_frame(path: Path, errors: list[str]) -> None:
    try:
        with Image.open(path) as opened:
            image = opened.convert("RGBA")
    except Exception as error:
        errors.append(f"{path}: unreadable frame: {error}")
        return
    if image.size != CELL_SIZE:
        errors.append(f"{path}: expected {CELL_SIZE[0]}x{CELL_SIZE[1]}, got {image.size}")
    alpha = image.getchannel("A")
    used = sum(alpha.histogram()[1:])
    if used < 400:
        errors.append(f"{path}: empty or too sparse ({used} pixels)")
    edge = alpha_edge_count(image)
    if edge > 24:
        errors.append(f"{path}: {edge} non-transparent pixels touch the cell edge")


def checkerboard(size: tuple[int, int], cell: int = 8) -> Image.Image:
    output = Image.new("RGBA", size, (232, 232, 232, 255))
    draw = ImageDraw.Draw(output)
    for y in range(0, size[1], cell):
        for x in range(0, size[0], cell):
            if (x // cell + y // cell) % 2:
                draw.rectangle((x, y, x + cell - 1, y + cell - 1), fill=(202, 202, 202, 255))
    return output


def make_contact_sheet(
    frame_map: dict[str, list[Path]],
    output: Path,
) -> None:
    label_width = 132
    scale = 0.5
    frame_width = round(CELL_SIZE[0] * scale)
    frame_height = round(CELL_SIZE[1] * scale)
    row_height = frame_height + 18
    sheet = Image.new(
        "RGBA",
        (label_width + frame_width * FRAME_COUNT, row_height * len(MOTION_ORDER)),
        (24, 24, 26, 255),
    )
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()
    for row_index, motion_id in enumerate(MOTION_ORDER):
        top = row_index * row_height
        draw.text((8, top + frame_height // 2 - 6), motion_id, fill=(245, 245, 247), font=font)
        for frame_index, path in enumerate(frame_map[motion_id]):
            with Image.open(path) as opened:
                frame = opened.convert("RGBA").resize(
                    (frame_width, frame_height), Image.Resampling.NEAREST
                )
            tile = checkerboard((frame_width, frame_height))
            tile.alpha_composite(frame)
            sheet.alpha_composite(tile, (label_width + frame_index * frame_width, top))
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.convert("RGB").save(output)


def make_reduce_motion_sheet(
    frame_map: dict[str, list[Path]],
    motion_definitions: dict[str, dict[str, Any]],
    output: Path,
) -> None:
    columns = 4
    tile_width = 224
    tile_height = 248
    rows = (len(MOTION_ORDER) + columns - 1) // columns
    sheet = Image.new("RGBA", (columns * tile_width, rows * tile_height), (24, 24, 26, 255))
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()
    for index, motion_id in enumerate(MOTION_ORDER):
        column = index % columns
        row = index // columns
        left = column * tile_width
        top = row * tile_height
        frame_index = motion_definitions[motion_id]["reduceMotionFrame"]
        with Image.open(frame_map[motion_id][frame_index]) as opened:
            frame = opened.convert("RGBA")
        tile = checkerboard(CELL_SIZE)
        tile.alpha_composite(frame)
        sheet.alpha_composite(tile, (left + 16, top + 20))
        draw.text((left + 16, top + 4), motion_id, fill=(245, 245, 247), font=font)
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.convert("RGB").save(output)


def make_watch_sheet(
    repo_root: Path,
    frame_map: dict[str, list[Path]],
    motion_definitions: dict[str, dict[str, Any]],
    size_name: str,
    output: Path,
) -> None:
    background_path = (
        repo_root
        / "Design/WatchCompanionAssets/backgrounds/spring_meadow_stream"
        / f"background-{size_name}.png"
    )
    with Image.open(background_path) as opened:
        background = opened.convert("RGBA")
    columns = 4
    rows = (len(MOTION_ORDER) + columns - 1) // columns
    label_height = 18
    sheet = Image.new(
        "RGBA",
        (background.width * columns, (background.height + label_height) * rows),
        (24, 24, 26, 255),
    )
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()
    for index, motion_id in enumerate(MOTION_ORDER):
        column = index % columns
        row = index // columns
        left = column * background.width
        top = row * (background.height + label_height)
        composite = background.copy()
        frame_index = motion_definitions[motion_id]["reduceMotionFrame"]
        with Image.open(frame_map[motion_id][frame_index]) as opened:
            frame = opened.convert("RGBA")
        character_left = round(background.width * 0.5 - frame.width / 2)
        character_top = round(background.height * 0.78 - frame.height)
        composite.alpha_composite(frame, (character_left, character_top))
        sheet.alpha_composite(composite, (left, top + label_height))
        draw.text((left + 4, top + 3), motion_id, fill=(245, 245, 247), font=font)
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.convert("RGB").save(output)


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    character_root = (
        repo_root / "Design/WatchCompanionAssets/characters" / f"{args.character}-v2"
    )
    product_root = character_root / "product-motion"
    manifest = read_json(product_root / "manifest.json")
    catalog = read_json(
        repo_root / "Design/WatchCompanionAssets/characters/motion-catalog.json"
    )
    definitions = {item["id"]: item for item in catalog["motions"]}
    jobs = {job["id"]: job for job in manifest["jobs"]}
    errors: list[str] = []
    warnings: list[str] = []

    if tuple(definitions) != MOTION_ORDER:
        errors.append("motion catalog order or IDs differ from the G4 product contract")
    expected_product_ids = set(MOTION_ORDER) - {"idle_neutral"}
    if set(jobs) != expected_product_ids:
        errors.append("product-motion manifest does not contain the required fifteen jobs")
    incomplete = sorted(job_id for job_id, job in jobs.items() if job["status"] != "complete")
    if incomplete:
        errors.append(f"incomplete product-motion jobs: {', '.join(incomplete)}")

    foundation_path = character_root / "final" / "spritesheet-extended.png"
    foundation_sha = sha256(foundation_path)
    if foundation_sha != manifest.get("foundationAtlasSha256"):
        errors.append("approved hatch-pet v2 foundation atlas changed during product-motion work")

    frame_map: dict[str, list[Path]] = {
        "idle_neutral": standard_row_frames(character_root, "idle")
    }
    for motion_id in MOTION_ORDER[1:]:
        try:
            review = read_json(product_root / "qa" / "rows" / motion_id / "review.json")
            if review.get("ok") is not True:
                errors.append(f"{motion_id}: incremental review did not pass")
            frame_map[motion_id] = product_frames(product_root, motion_id)
        except (FileNotFoundError, json.JSONDecodeError) as error:
            errors.append(str(error))

    if not errors:
        for motion_id, paths in frame_map.items():
            for path in paths:
                validate_frame(path, errors)

    canonical_hashes = {
        row: sequence_sha256(standard_row_frames(character_root, row))
        for row in CANONICAL_ROWS
    }
    sequence_hashes: dict[str, str] = {}
    if not errors:
        sequence_hashes = {
            motion_id: sequence_sha256(paths) for motion_id, paths in frame_map.items()
        }
        product_hashes = [
            sequence_hashes[motion_id] for motion_id in MOTION_ORDER if motion_id != "idle_neutral"
        ]
        if len(set(product_hashes)) != len(product_hashes):
            errors.append("two dedicated product motions have identical frame sequences")
        for motion_id in MOTION_ORDER[1:]:
            matching_rows = [
                row for row, digest in canonical_hashes.items() if digest == sequence_hashes[motion_id]
            ]
            if matching_rows:
                errors.append(
                    f"{motion_id}: dedicated product clip duplicates hatch-pet row "
                    f"{', '.join(matching_rows)}"
                )

    output_manifest: dict[str, Any] = {}
    if not errors:
        final_root = product_root / "final"
        final_root.mkdir(parents=True, exist_ok=True)
        output_manifest = {
            "schemaVersion": 1,
            "characterID": args.character,
            "status": "ready",
            "foundationAtlasSha256": foundation_sha,
            "frameCount": FRAME_COUNT,
            "cell": {"width": CELL_SIZE[0], "height": CELL_SIZE[1]},
            "motions": [
                {
                    "id": motion_id,
                    "sourceKind": definitions[motion_id]["source"]["kind"],
                    "playback": definitions[motion_id]["playback"],
                    "framesPerSecond": catalog["defaults"]["framesPerSecond"],
                    "reduceMotionFrame": definitions[motion_id]["reduceMotionFrame"],
                    "sequenceSha256": sequence_hashes[motion_id],
                    "frames": [
                        str(path.relative_to(repo_root)) for path in frame_map[motion_id]
                    ],
                    "assetNames": [
                        f"character_{args.character}_{motion_id}_{index:02d}"
                        for index in range(FRAME_COUNT)
                    ],
                }
                for motion_id in MOTION_ORDER
            ],
        }
        (final_root / "motion-manifest.json").write_text(
            json.dumps(output_manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        make_contact_sheet(frame_map, product_root / "qa" / "contact-sheet.png")
        make_reduce_motion_sheet(
            frame_map,
            definitions,
            product_root / "qa" / "reduce-motion-keyframes.png",
        )
        make_watch_sheet(
            repo_root,
            frame_map,
            definitions,
            "small",
            product_root / "qa" / "watch-small-contact-sheet.png",
        )
        make_watch_sheet(
            repo_root,
            frame_map,
            definitions,
            "large",
            product_root / "qa" / "watch-large-contact-sheet.png",
        )

    validation = {
        "ok": not errors,
        "characterID": args.character,
        "foundationAtlasSha256": foundation_sha,
        "motionCount": len(output_manifest.get("motions", [])),
        "errors": errors,
        "warnings": warnings,
    }
    validation_path = product_root / "final" / "validation.json"
    validation_path.parent.mkdir(parents=True, exist_ok=True)
    validation_path.write_text(
        json.dumps(validation, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(validation, ensure_ascii=False, indent=2))
    return 0 if validation["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
