#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from collections import deque
from pathlib import Path
from typing import Any

from PIL import Image


def connected_components(
    alpha: bytes,
    width: int,
    height: int,
    threshold: int,
) -> list[list[int]]:
    visited = bytearray(width * height)
    components: list[list[int]] = []
    for start, value in enumerate(alpha):
        if value <= threshold or visited[start]:
            continue
        queue = deque([start])
        visited[start] = 1
        component: list[int] = []
        while queue:
            current = queue.pop()
            component.append(current)
            x = current % width
            y = current // width
            for neighbor in (
                current - 1 if x > 0 else -1,
                current + 1 if x + 1 < width else -1,
                current - width if y > 0 else -1,
                current + width if y + 1 < height else -1,
            ):
                if (
                    neighbor >= 0
                    and not visited[neighbor]
                    and alpha[neighbor] > threshold
                ):
                    visited[neighbor] = 1
                    queue.append(neighbor)
        components.append(component)
    return components


def clean_frame(
    path: Path,
    *,
    alpha_threshold: int = 4,
    halo_radius: int = 2,
) -> dict[str, Any]:
    with Image.open(path) as opened:
        image = opened.convert("RGBA")
    width, height = image.size
    alpha = image.getchannel("A").tobytes()
    components = connected_components(alpha, width, height, alpha_threshold)
    if not components:
        raise ValueError(f"{path}: no visible sprite component")
    components.sort(key=len, reverse=True)
    main = components[0]
    if len(main) < 1_000:
        raise ValueError(f"{path}: largest sprite component is unexpectedly small")

    keep = bytearray(width * height)
    for pixel in main:
        x = pixel % width
        y = pixel // width
        for offset_y in range(-halo_radius, halo_radius + 1):
            target_y = y + offset_y
            if not 0 <= target_y < height:
                continue
            for offset_x in range(-halo_radius, halo_radius + 1):
                target_x = x + offset_x
                if 0 <= target_x < width:
                    keep[target_y * width + target_x] = 1

    pixels = image.load()
    removed_pixels = 0
    for index, should_keep in enumerate(keep):
        x = index % width
        y = index // width
        if pixels[x, y][3] and not should_keep:
            pixels[x, y] = (0, 0, 0, 0)
            removed_pixels += 1
    image.save(path, format="PNG", optimize=True)
    return {
        "path": str(path),
        "componentCount": len(components),
        "largestComponentPixels": len(main),
        "removedPixels": removed_pixels,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Remove detached neighboring-sprite fragments from normalized RGBA frames."
    )
    parser.add_argument("--frames-dir", type=Path, action="append", required=True)
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--alpha-threshold", type=int, default=4)
    parser.add_argument("--halo-radius", type=int, default=2)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    results: list[dict[str, Any]] = []
    for frames_dir in args.frames_dir:
        paths = sorted(frames_dir.resolve().glob("*.png"))
        if not paths:
            raise FileNotFoundError(f"no PNG frames in {frames_dir}")
        results.extend(
            clean_frame(
                path,
                alpha_threshold=args.alpha_threshold,
                halo_radius=args.halo_radius,
            )
            for path in paths
        )
    report = {
        "ok": True,
        "alphaThreshold": args.alpha_threshold,
        "haloRadius": args.halo_radius,
        "frames": results,
        "removedPixels": sum(item["removedPixels"] for item in results),
    }
    output = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(output, encoding="utf-8")
    print(output, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
