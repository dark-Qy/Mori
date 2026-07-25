#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import math
from collections import Counter
from pathlib import Path
from statistics import median
from typing import Any

from PIL import Image


CELL_SIZE = (192, 208)
FRAME_COUNT = 8
ALPHA_THRESHOLD = 16
CHROMA_THRESHOLD = 96.0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract and validate generated Mori product-motion strips."
    )
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--character", required=True, choices=("penguin", "polar_bear"))
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--motion")
    selection.add_argument("--all", action="store_true")
    return parser.parse_args()


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def color_distance(left: tuple[int, int, int], right: tuple[int, int, int]) -> float:
    return math.sqrt(sum((left[index] - right[index]) ** 2 for index in range(3)))


def parse_hex(value: str) -> tuple[int, int, int]:
    if len(value) != 7 or not value.startswith("#"):
        raise ValueError(f"invalid RGB hex value: {value}")
    return tuple(int(value[index : index + 2], 16) for index in (1, 3, 5))


def remove_chroma_background(
    image: Image.Image,
    key: tuple[int, int, int],
    threshold: float = CHROMA_THRESHOLD,
) -> Image.Image:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if color_distance((red, green, blue), key) <= threshold:
                pixels[x, y] = (0, 0, 0, 0)
            elif alpha == 0:
                pixels[x, y] = (0, 0, 0, 0)
    return rgba


def border_key_evidence(
    image: Image.Image,
    key: tuple[int, int, int],
) -> dict[str, Any]:
    rgb = image.convert("RGB")
    border: list[tuple[int, int, int]] = []
    border.extend(rgb.crop((0, 0, rgb.width, 3)).get_flattened_data())
    border.extend(
        rgb.crop((0, rgb.height - 3, rgb.width, rgb.height)).get_flattened_data()
    )
    border.extend(rgb.crop((0, 0, 3, rgb.height)).get_flattened_data())
    border.extend(
        rgb.crop((rgb.width - 3, 0, rgb.width, rgb.height)).get_flattened_data()
    )
    dominant, _ = Counter(border).most_common(1)[0]
    uniform = sum(color_distance(pixel, dominant) <= 12 for pixel in border)
    compatible = sum(color_distance(pixel, key) <= CHROMA_THRESHOLD for pixel in border)
    return {
        "dominantRGB": list(dominant),
        "uniformRatio": uniform / max(1, len(border)),
        "requestedKeyCompatibleRatio": compatible / max(1, len(border)),
        "dominantDistanceFromRequestedKey": color_distance(dominant, key),
    }


def connected_components(image: Image.Image) -> list[dict[str, Any]]:
    alpha = image.getchannel("A")
    width, height = alpha.size
    data = alpha.tobytes()
    visited = bytearray(width * height)
    components: list[dict[str, Any]] = []

    for start, alpha_value in enumerate(data):
        if alpha_value <= ALPHA_THRESHOLD or visited[start]:
            continue
        stack = [start]
        visited[start] = 1
        pixels: list[int] = []
        min_x, min_y, max_x, max_y = width, height, 0, 0

        while stack:
            current = stack.pop()
            pixels.append(current)
            x = current % width
            y = current // width
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
            for neighbor in (
                current - 1 if x > 0 else None,
                current + 1 if x + 1 < width else None,
                current - width if y > 0 else None,
                current + width if y + 1 < height else None,
            ):
                if (
                    neighbor is not None
                    and not visited[neighbor]
                    and data[neighbor] > ALPHA_THRESHOLD
                ):
                    visited[neighbor] = 1
                    stack.append(neighbor)

        components.append(
            {
                "pixels": pixels,
                "area": len(pixels),
                "bbox": (min_x, min_y, max_x + 1, max_y + 1),
                "centerX": (min_x + max_x + 1) / 2,
            }
        )
    return components


def group_components(
    image: Image.Image,
    expected_count: int,
) -> list[list[dict[str, Any]]]:
    components = connected_components(image)
    if not components:
        raise ValueError("no non-transparent sprite components found")

    largest_area = max(component["area"] for component in components)
    seed_threshold = max(120, largest_area * 0.20)
    seeds = [component for component in components if component["area"] >= seed_threshold]
    if len(seeds) < expected_count:
        seeds = sorted(components, key=lambda item: item["area"], reverse=True)[:expected_count]
    if len(seeds) < expected_count:
        raise ValueError(f"found only {len(seeds)} pose seeds; expected {expected_count}")

    seeds = sorted(
        sorted(seeds, key=lambda item: item["area"], reverse=True)[:expected_count],
        key=lambda item: item["centerX"],
    )
    minimum_spacing = image.width / expected_count * 0.35
    for left, right in zip(seeds, seeds[1:]):
        if right["centerX"] - left["centerX"] < minimum_spacing:
            raise ValueError("pose seeds are too close or overlap")

    seed_ids = {id(seed) for seed in seeds}
    groups: list[list[dict[str, Any]]] = [[seed] for seed in seeds]
    noise_threshold = max(12, largest_area * 0.002)
    for component in components:
        if id(component) in seed_ids or component["area"] < noise_threshold:
            continue
        nearest = min(
            range(len(seeds)),
            key=lambda index: abs(seeds[index]["centerX"] - component["centerX"]),
        )
        groups[nearest].append(component)
    return groups


def group_bbox(group: list[dict[str, Any]]) -> tuple[int, int, int, int]:
    return (
        min(component["bbox"][0] for component in group),
        min(component["bbox"][1] for component in group),
        max(component["bbox"][2] for component in group),
        max(component["bbox"][3] for component in group),
    )


def paint_group(
    source: Image.Image,
    group: list[dict[str, Any]],
    *,
    shared_top: int,
    viewport_width: int,
    viewport_height: int,
) -> Image.Image:
    source_width, _ = source.size
    bbox = group_bbox(group)
    group_width = bbox[2] - bbox[0]
    left = (viewport_width - group_width) // 2
    output = Image.new("RGBA", (viewport_width, viewport_height), (0, 0, 0, 0))
    source_pixels = source.load()
    output_pixels = output.load()
    for component in group:
        for pixel_index in component["pixels"]:
            source_x = pixel_index % source_width
            source_y = pixel_index // source_width
            output_x = left + source_x - bbox[0]
            output_y = source_y - shared_top
            if 0 <= output_x < viewport_width and 0 <= output_y < viewport_height:
                output_pixels[output_x, output_y] = source_pixels[source_x, source_y]
    return output


def fit_shared_viewport(viewport: Image.Image, scale: float) -> Image.Image:
    width = max(1, round(viewport.width * scale))
    height = max(1, round(viewport.height * scale))
    resized = viewport.resize((width, height), Image.Resampling.LANCZOS)
    output = Image.new("RGBA", CELL_SIZE, (0, 0, 0, 0))
    left = (CELL_SIZE[0] - width) // 2
    top = (CELL_SIZE[1] - height) // 2
    output.alpha_composite(resized, (left, top))
    return output


def extract_frames(strip: Image.Image) -> tuple[list[Image.Image], list[list[int]]]:
    groups = group_components(strip, FRAME_COUNT)
    bboxes = [group_bbox(group) for group in groups]
    padding = 4
    shared_top = max(0, min(bbox[1] for bbox in bboxes) - padding)
    shared_bottom = min(strip.height, max(bbox[3] for bbox in bboxes) + padding)
    viewport_width = max(bbox[2] - bbox[0] for bbox in bboxes) + padding * 2
    viewport_height = shared_bottom - shared_top
    scale = min(
        (CELL_SIZE[0] - 10) / viewport_width,
        (CELL_SIZE[1] - 10) / viewport_height,
        1.0,
    )
    frames = [
        fit_shared_viewport(
            paint_group(
                strip,
                group,
                shared_top=shared_top,
                viewport_width=viewport_width,
                viewport_height=viewport_height,
            ),
            scale,
        )
        for group in groups
    ]
    return frames, [list(bbox) for bbox in bboxes]


def nontransparent_area(image: Image.Image) -> int:
    return sum(image.getchannel("A").histogram()[1:])


def edge_alpha_pixels(image: Image.Image, margin: int = 2) -> int:
    alpha = image.getchannel("A")
    width, height = alpha.size
    total = 0
    for box in (
        (0, 0, width, margin),
        (0, height - margin, width, height),
        (0, 0, margin, height),
        (width - margin, 0, width, height),
    ):
        total += sum(alpha.crop(box).histogram()[1:])
    return total


def frame_digest(image: Image.Image) -> str:
    return hashlib.sha256(image.tobytes()).hexdigest()


def inspect_frames(
    frames: list[Image.Image],
    sequence_type: str,
) -> tuple[list[dict[str, Any]], list[str], list[str]]:
    details: list[dict[str, Any]] = []
    errors: list[str] = []
    warnings: list[str] = []
    areas: list[int] = []
    bottoms: list[int] = []
    digests: list[str] = []

    for index, frame in enumerate(frames):
        bbox = frame.getbbox()
        area = nontransparent_area(frame)
        edge_pixels = edge_alpha_pixels(frame)
        digest = frame_digest(frame)
        areas.append(area)
        bottoms.append(bbox[3] if bbox else 0)
        digests.append(digest)
        details.append(
            {
                "index": index,
                "size": list(frame.size),
                "bbox": list(bbox) if bbox else None,
                "nontransparentPixels": area,
                "edgePixels": edge_pixels,
                "sha256": digest,
            }
        )
        if frame.size != CELL_SIZE:
            errors.append(f"frame {index:02d} has invalid dimensions {frame.size}")
        if area < 400:
            errors.append(f"frame {index:02d} is empty or too sparse")
        if edge_pixels > 24:
            errors.append(f"frame {index:02d} touches the cell edge ({edge_pixels} pixels)")

    unique_frames = len(set(digests))
    required_unique = 3 if sequence_type == "loop" else 4
    if unique_frames < required_unique:
        errors.append(
            f"motion has only {unique_frames} unique frames; expected at least {required_unique}"
        )

    if areas:
        typical_area = median(areas)
        for index, area in enumerate(areas):
            if area < typical_area * 0.45 or area > typical_area * 1.8:
                warnings.append(
                    f"frame {index:02d} area {area} differs materially from median {typical_area:.0f}"
                )
    if bottoms and max(bottoms) - min(bottoms) > 10:
        warnings.append(f"frame baseline range is {max(bottoms) - min(bottoms)} pixels")
    return details, errors, warnings


def save_preview(
    frames: list[Image.Image],
    sequence_type: str,
    output: Path,
) -> None:
    durations = [100] * len(frames)
    if sequence_type != "loop":
        durations[-1] = 400 if sequence_type == "oneShotHoldFinal" else 250
    output.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        output,
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=0,
        disposal=2,
        optimize=False,
    )


def process_job(
    *,
    product_root: Path,
    manifest: dict[str, Any],
    job: dict[str, Any],
) -> dict[str, Any]:
    source = product_root / job["outputPath"]
    if not source.is_file():
        raise FileNotFoundError(f"missing selected generated strip: {source}")

    with Image.open(source) as opened:
        opened.load()
        source_size = opened.size
        source_mode = opened.mode
        key = parse_hex(manifest["chromaKey"])
        border_evidence = border_key_evidence(opened, key)
        strip = remove_chroma_background(opened, key)

    errors: list[str] = []
    warnings: list[str] = []
    ratio = source_size[0] / max(1, source_size[1])
    if ratio < 1.8 or ratio > 3.5:
        errors.append(f"source aspect ratio {ratio:.3f} cannot safely hold eight horizontal poses")
    elif ratio < 2.5 or ratio > 3.2:
        warnings.append(
            f"source aspect ratio {ratio:.3f} differs from the preferred 2.5...3.2 range"
        )
    if border_evidence["uniformRatio"] < 0.80:
        errors.append(
            "source border is not a sufficiently flat chroma background "
            f"({border_evidence['uniformRatio']:.1%} uniform)"
        )
    elif border_evidence["uniformRatio"] < 0.95:
        warnings.append(
            "source border has minor color variation but remains within the selected chroma "
            f"threshold ({border_evidence['uniformRatio']:.1%} locally uniform)"
        )
    if border_evidence["requestedKeyCompatibleRatio"] < 0.95:
        errors.append(
            "source border is not compatible with the requested chroma key "
            f"({border_evidence['requestedKeyCompatibleRatio']:.1%} within threshold)"
        )

    try:
        frames, source_bboxes = extract_frames(strip)
    except ValueError as error:
        frames = []
        source_bboxes = []
        errors.append(str(error))

    frame_details: list[dict[str, Any]] = []
    if frames:
        frame_details, frame_errors, frame_warnings = inspect_frames(
            frames, job["sequenceType"]
        )
        errors.extend(frame_errors)
        warnings.extend(frame_warnings)

    frame_root = product_root / "frames" / job["id"]
    if not errors:
        frame_root.mkdir(parents=True, exist_ok=True)
        for index, frame in enumerate(frames):
            frame.save(frame_root / f"{index:02d}.png")
        save_preview(
            frames,
            job["sequenceType"],
            product_root / "qa" / "previews" / f"{job['id']}.gif",
        )

    result = {
        "ok": not errors,
        "motionID": job["id"],
        "sequenceType": job["sequenceType"],
        "source": {
            "path": str(source),
            "size": list(source_size),
            "mode": source_mode,
            "borderKeyEvidence": border_evidence,
            "poseSourceBBoxes": source_bboxes,
        },
        "errors": errors,
        "warnings": warnings,
        "frames": frame_details,
    }
    review_path = product_root / "qa" / "rows" / job["id"] / "review.json"
    review_path.parent.mkdir(parents=True, exist_ok=True)
    review_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    product_root = (
        repo_root
        / "Design/WatchCompanionAssets/characters"
        / f"{args.character}-v2"
        / "product-motion"
    )
    manifest = read_json(product_root / "manifest.json")
    jobs = manifest["jobs"]
    selected = (
        [job for job in jobs if job["status"] == "complete"]
        if args.all
        else [job for job in jobs if job["id"] == args.motion]
    )
    if not selected:
        raise ValueError("no matching product-motion job is available to process")

    results = [
        process_job(product_root=product_root, manifest=manifest, job=job)
        for job in selected
    ]
    summary = {
        "ok": all(result["ok"] for result in results),
        "characterID": args.character,
        "motions": [
            {
                "id": result["motionID"],
                "ok": result["ok"],
                "errors": result["errors"],
                "warnings": result["warnings"],
            }
            for result in results
        ],
    }
    print(json.dumps(summary, indent=2))
    return 0 if summary["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
