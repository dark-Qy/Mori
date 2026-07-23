#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compose scene QA images from independent layers.")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    return parser.parse_args()


def absolute(repo_root: Path, value: str | Path) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def place_character(
    canvas: Image.Image,
    frame: Image.Image,
    slot: dict,
) -> None:
    scale = float(slot["scale"])
    width = round(frame.width * scale)
    height = round(frame.height * scale)
    resized = frame.resize((width, height), Image.Resampling.NEAREST)
    center_x = round(canvas.width * float(slot["x"]))
    foot_y = round(canvas.height * float(slot["footY"]))
    canvas.alpha_composite(resized, (center_x - width // 2, foot_y - height))


def contact_sheet(paths: list[Path], output: Path, columns: int = 5) -> None:
    thumb = (166, 198)
    label_height = 25
    rows = (len(paths) + columns - 1) // columns
    sheet = Image.new("RGB", (thumb[0] * columns, (thumb[1] + label_height) * rows), "#111214")
    draw = ImageDraw.Draw(sheet)
    for index, path in enumerate(paths):
        with Image.open(path) as source:
            image = source.convert("RGB").resize(thumb, Image.Resampling.NEAREST)
        x = index % columns * thumb[0]
        y = index // columns * (thumb[1] + label_height)
        sheet.paste(image, (x, y))
        draw.text((x + 5, y + thumb[1] + 5), path.stem, fill="white")
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output, format="PNG", optimize=True)


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    background_catalog = json.loads(
        (repo_root / "Design/WatchCompanionAssets/backgrounds/catalog.json").read_text(
            encoding="utf-8"
        )
    )
    character_catalog = json.loads(
        (repo_root / "Design/WatchCompanionAssets/characters/catalog.json").read_text(
            encoding="utf-8"
        )
    )
    slots = background_catalog["defaultSlots"]
    frames: dict[str, Image.Image] = {}
    for character in character_catalog["characters"]:
        path = (
            absolute(repo_root, character["runDirectory"])
            / "qa"
            / "rows"
            / "idle"
            / "frames"
            / "idle"
            / "00.png"
        )
        if not path.is_file():
            raise FileNotFoundError(f"{character['id']}: missing validated idle key frame {path}")
        with Image.open(path) as frame:
            frames[character["id"]] = frame.convert("RGBA")

    qa_root = repo_root / "Design/WatchCompanionAssets/qa/composites"
    single_paths: list[Path] = []
    duo_paths: list[Path] = []
    for scene in background_catalog["backgrounds"]:
        with Image.open(absolute(repo_root, scene["large"])) as background:
            base = background.convert("RGBA")
        for character_id, frame in frames.items():
            composite = base.copy()
            place_character(composite, frame, slots["solo.center"])
            output = qa_root / "single" / f"{scene['id']}-{character_id}.png"
            output.parent.mkdir(parents=True, exist_ok=True)
            composite.convert("RGB").save(output, format="PNG", optimize=True)
            single_paths.append(output)

        duo = base.copy()
        place_character(duo, frames["penguin"], slots["duo.left"])
        place_character(duo, frames["polar_bear"], slots["duo.right"])
        output = qa_root / "duo" / f"{scene['id']}-duo.png"
        output.parent.mkdir(parents=True, exist_ok=True)
        duo.convert("RGB").save(output, format="PNG", optimize=True)
        duo_paths.append(output)

    contact_sheet(single_paths, qa_root / "single-contact-sheet.png")
    contact_sheet(duo_paths, qa_root / "duo-contact-sheet.png")
    print(
        json.dumps(
            {
                "ok": True,
                "singleComposites": len(single_paths),
                "duoComposites": len(duo_paths),
                "singleContactSheet": str(qa_root / "single-contact-sheet.png"),
                "duoContactSheet": str(qa_root / "duo-contact-sheet.png"),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
