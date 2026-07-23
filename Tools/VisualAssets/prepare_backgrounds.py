#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepare Watch Companion background PNG variants.")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument(
        "--catalog",
        type=Path,
        default=Path("Design/WatchCompanionAssets/backgrounds/catalog.json"),
    )
    parser.add_argument(
        "--contact-sheet",
        type=Path,
        default=Path("Design/WatchCompanionAssets/qa/background-contact-sheet.png"),
    )
    return parser.parse_args()


def absolute(repo_root: Path, value: str | Path) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def fit_pixel_art(
    image: Image.Image, size: tuple[int, int], center: tuple[float, float]
) -> Image.Image:
    return ImageOps.fit(
        image.convert("RGB"),
        size,
        method=Image.Resampling.NEAREST,
        centering=center,
    )


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    catalog_path = absolute(repo_root, args.catalog)
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    sizes = {
        key: (int(value["width"]), int(value["height"]))
        for key, value in catalog["canvas"].items()
    }
    prepared: list[tuple[str, str, Image.Image]] = []

    for scene in catalog["backgrounds"]:
        source_path = absolute(repo_root, scene["source"])
        if not source_path.is_file():
            raise FileNotFoundError(f"{scene['id']}: missing source {source_path}")
        center_value = scene.get("cropCenter", {"x": 0.5, "y": 0.5})
        center = (float(center_value["x"]), float(center_value["y"]))
        with Image.open(source_path) as source:
            source.load()
            master = fit_pixel_art(source, sizes["master"], center)
        outputs = {
            "master": master,
            "small": fit_pixel_art(master, sizes["small"], center),
            "large": fit_pixel_art(master, sizes["large"], center),
        }
        for key, output in outputs.items():
            output_path = absolute(repo_root, scene[key])
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output.save(output_path, format="PNG", optimize=True)
        prepared.append((scene["id"], scene["displayName"], master))

    thumb_size = (208, 256)
    label_height = 28
    columns = 5
    rows = (len(prepared) + columns - 1) // columns
    sheet = Image.new(
        "RGB",
        (columns * thumb_size[0], rows * (thumb_size[1] + label_height)),
        "#101114",
    )
    draw = ImageDraw.Draw(sheet)
    for index, (scene_id, display_name, master) in enumerate(prepared):
        x = (index % columns) * thumb_size[0]
        y = (index // columns) * (thumb_size[1] + label_height)
        thumb = master.resize(thumb_size, Image.Resampling.NEAREST)
        sheet.paste(thumb, (x, y))
        draw.text((x + 6, y + thumb_size[1] + 6), f"{index + 1}. {scene_id}", fill="white")
    contact_path = absolute(repo_root, args.contact_sheet)
    contact_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(contact_path, format="PNG", optimize=True)
    print(
        json.dumps(
            {
                "ok": True,
                "prepared": len(prepared),
                "contactSheet": str(contact_path),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

