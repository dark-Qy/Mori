#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw


FRAME_SIZE = (192, 208)
FRAME_COUNT = 8
CHROMA_KEY = (255, 0, 255)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate and render the supplementary social-leap rows."
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
    )
    return parser.parse_args()


def color_distance(left: tuple[int, int, int], right: tuple[int, int, int]) -> float:
    return math.sqrt(
        sum((left[index] - right[index]) ** 2 for index in range(3))
    )


def edge_alpha_count(image: Image.Image, margin: int = 2) -> int:
    alpha = image.getchannel("A")
    width, height = image.size
    boxes = (
        (0, 0, width, margin),
        (0, height - margin, width, height),
        (0, 0, margin, height),
        (width - margin, 0, width, height),
    )
    return sum(
        sum(crop.histogram()[1:])
        for crop in (alpha.crop(box) for box in boxes)
    )


def visible_near_chroma_count(image: Image.Image) -> int:
    count = 0
    pixels = (
        image.get_flattened_data()
        if hasattr(image, "get_flattened_data")
        else image.getdata()
    )
    for red, green, blue, alpha in pixels:
        if alpha > 16 and color_distance((red, green, blue), CHROMA_KEY) <= 150:
            count += 1
    return count


def render_contact_sheet(frames: list[Image.Image], output: Path) -> None:
    scale = 2
    cell_width = FRAME_SIZE[0] * scale
    cell_height = FRAME_SIZE[1] * scale
    sheet = Image.new("RGB", (cell_width * FRAME_COUNT, cell_height), "#172231")
    draw = ImageDraw.Draw(sheet)
    for index, frame in enumerate(frames):
        enlarged = frame.resize(
            (cell_width, cell_height),
            Image.Resampling.NEAREST,
        )
        sheet.paste(enlarged, (index * cell_width, 0), enlarged)
        draw.text(
            (index * cell_width + 10, 10),
            f"{index}",
            fill="white",
            stroke_width=2,
            stroke_fill="black",
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output)


def render_preview(frames: list[Image.Image], output: Path) -> None:
    preview_frames: list[Image.Image] = []
    for frame in frames:
        canvas = Image.new("RGBA", FRAME_SIZE, "#172231")
        canvas.alpha_composite(frame)
        preview_frames.append(canvas.convert("RGB"))
    preview_frames[0].save(
        output,
        save_all=True,
        append_images=preview_frames[1:],
        duration=[110, 100, 100, 100, 130, 100, 120, 320],
        loop=0,
        disposal=2,
        optimize=False,
    )


def validate_character(
    repo_root: Path,
    character_id: str,
    run_directory: Path,
) -> tuple[dict[str, object], list[str]]:
    errors: list[str] = []
    row_root = run_directory / "qa/rows/social-leap"
    frames_root = row_root / "frames/social-leap"
    source = run_directory / "decoded/social-leap.png"
    canonical = run_directory / "references/canonical-base.png"
    identity_review_path = row_root / "identity-review.json"
    frame_paths = [frames_root / f"{index:02d}.png" for index in range(FRAME_COUNT)]
    unexpected = sorted(
        path.name
        for path in frames_root.glob("*.png")
        if path not in frame_paths
    )
    if unexpected:
        errors.append(f"{character_id}: unexpected social-leap frames: {unexpected}")
    if not source.is_file():
        errors.append(f"{character_id}: missing decoded social-leap source strip")
    identity_review: dict[str, object] | None = None
    if not identity_review_path.is_file():
        errors.append(f"{character_id}: independent identity review evidence is missing")
    else:
        try:
            identity_review = json.loads(identity_review_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as error:
            errors.append(f"{character_id}: invalid identity review evidence: {error}")
        if identity_review is not None:
            expected_hashes = {
                "canonicalBaseSHA256": (
                    hashlib.sha256(canonical.read_bytes()).hexdigest()
                    if canonical.is_file()
                    else None
                ),
                "socialLeapSourceSHA256": (
                    hashlib.sha256(source.read_bytes()).hexdigest()
                    if source.is_file()
                    else None
                ),
            }
            if identity_review.get("schemaVersion") != "social_leap_identity_review_v1":
                errors.append(f"{character_id}: identity review schema is unsupported")
            if identity_review.get("verdict") != "passed":
                errors.append(f"{character_id}: identity review did not pass")
            if identity_review.get("reviewer") in {None, "", "self-attested"}:
                errors.append(f"{character_id}: independent reviewer is not identified")
            for field, expected in expected_hashes.items():
                if identity_review.get(field) != expected:
                    errors.append(
                        f"{character_id}: identity review {field} does not match current asset"
                    )

    frames: list[Image.Image] = []
    frame_evidence: list[dict[str, object]] = []
    for index, path in enumerate(frame_paths):
        if not path.is_file():
            errors.append(f"{character_id}: missing frame {index:02d}")
            continue
        with Image.open(path) as opened:
            if opened.format != "PNG":
                errors.append(f"{character_id}: frame {index:02d} is not PNG")
            frame = opened.convert("RGBA")
        frames.append(frame)
        bbox = frame.getbbox()
        nontransparent = sum(frame.getchannel("A").histogram()[1:])
        edge_pixels = edge_alpha_count(frame)
        near_chroma = visible_near_chroma_count(frame)
        if frame.size != FRAME_SIZE:
            errors.append(
                f"{character_id}: frame {index:02d} is "
                f"{frame.width}x{frame.height}, expected 192x208"
            )
        if bbox is None or nontransparent < 400:
            errors.append(f"{character_id}: frame {index:02d} is empty or too sparse")
        if edge_pixels > 24:
            errors.append(
                f"{character_id}: frame {index:02d} has {edge_pixels} edge pixels"
            )
        if near_chroma > 800:
            errors.append(
                f"{character_id}: frame {index:02d} retains {near_chroma} chroma-like pixels"
            )
        frame_evidence.append(
            {
                "index": index,
                "path": str(path.relative_to(repo_root)),
                "size": [frame.width, frame.height],
                "bbox": list(bbox) if bbox else None,
                "nontransparentPixels": nontransparent,
                "edgePixels": edge_pixels,
                "chromaAdjacentPixels": near_chroma,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        )

    if len(frames) == FRAME_COUNT:
        tops = [frame.getbbox()[1] for frame in frames if frame.getbbox()]
        bottoms = [frame.getbbox()[3] for frame in frames if frame.getbbox()]
        if len(tops) != FRAME_COUNT or tops[4] != min(tops):
            errors.append(f"{character_id}: frame 04 must be the jump apex")
        if not (bottoms[0] >= 200 and bottoms[1] >= 200):
            errors.append(f"{character_id}: ready/compression frames must remain grounded")
        if not (bottoms[6] >= 200 and bottoms[7] >= 200):
            errors.append(f"{character_id}: landing/recovery frames must return to ground")
        render_contact_sheet(frames, row_root / "contact-sheet.png")
        render_preview(frames, run_directory / "qa/previews/social-leap.gif")

    result = {
        "ok": not errors,
        "characterID": character_id,
        "state": "social-leap",
        "frameCount": len(frames),
        "extractionMethod": "stable-slots",
        "canonicalIdentityReview": "passed" if identity_review is not None else "missing",
        "identityReviewEvidence": (
            str(identity_review_path.relative_to(repo_root))
            if identity_review is not None
            else None
        ),
        "motionSemantics": [
            "ready",
            "compression",
            "push-off",
            "rise",
            "apex",
            "descent",
            "landing",
            "recovery",
        ],
        "source": str(source.relative_to(repo_root)) if source.is_file() else None,
        "frames": frame_evidence,
        "errors": errors,
    }
    row_root.mkdir(parents=True, exist_ok=True)
    (row_root / "review.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return result, errors


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    catalog = json.loads(
        (repo_root / "Design/WatchCompanionAssets/characters/catalog.json").read_text(
            encoding="utf-8"
        )
    )
    results: list[dict[str, object]] = []
    errors: list[str] = []
    for character in catalog["characters"]:
        run_directory = repo_root / character["runDirectory"]
        result, character_errors = validate_character(
            repo_root,
            character["id"],
            run_directory,
        )
        results.append(result)
        errors.extend(character_errors)
    output = {"ok": not errors, "characters": results, "errors": errors}
    print(json.dumps(output, ensure_ascii=False, indent=2))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
