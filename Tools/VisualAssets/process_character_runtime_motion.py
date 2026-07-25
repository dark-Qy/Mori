#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

from clean_character_frame_fragments import clean_frame


FRAME_COUNT = 8
FRAME_SIZE = (192, 208)
CHROMA_KEY = "#FF00FF"
CHROMA_THRESHOLD = "170"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract, validate, and render QA for one 8-frame runtime motion strip."
    )
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument(
        "--state",
        required=True,
        choices=("touch_head", "touch_body", "social_leap"),
    )
    parser.add_argument(
        "--skill-dir",
        type=Path,
        default=Path.home() / ".codex/skills/hatch-pet",
    )
    parser.add_argument("--allow-stable-slots", action="store_true")
    return parser.parse_args()


def run_command(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        check=False,
        capture_output=True,
        text=True,
    )


def render_contact_sheet(frames: list[Image.Image], output: Path) -> None:
    scale = 2
    cell_width = FRAME_SIZE[0] * scale
    cell_height = FRAME_SIZE[1] * scale
    sheet = Image.new("RGB", (cell_width * FRAME_COUNT, cell_height), "#172231")
    draw = ImageDraw.Draw(sheet)
    for index, frame in enumerate(frames):
        enlarged = frame.resize((cell_width, cell_height), Image.Resampling.NEAREST)
        x = index * cell_width
        sheet.paste(enlarged, (x, 0), enlarged)
        draw.text(
            (x + 10, 10),
            f"{index:02d}",
            fill="white",
            stroke_width=2,
            stroke_fill="black",
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output, format="PNG", optimize=True)


def render_preview(frames: list[Image.Image], output: Path) -> None:
    preview_frames: list[Image.Image] = []
    for frame in frames:
        canvas = Image.new("RGBA", FRAME_SIZE, "#172231")
        canvas.alpha_composite(frame)
        preview_frames.append(canvas.convert("RGB"))
    output.parent.mkdir(parents=True, exist_ok=True)
    preview_frames[0].save(
        output,
        save_all=True,
        append_images=preview_frames[1:],
        duration=[167, 167, 167, 167, 167, 167, 167, 334],
        loop=0,
        disposal=2,
        optimize=False,
    )


def main() -> int:
    args = parse_args()
    run_dir = args.run_dir.resolve()
    skill_dir = args.skill_dir.resolve()
    motion_root = run_dir / "product-motion"
    source = motion_root / "decoded" / f"{args.state}.png"
    if not source.is_file():
        raise FileNotFoundError(source)

    qa_root = motion_root / "qa" / args.state
    extraction_root = qa_root / "extraction"
    decoded_root = extraction_root / "decoded"
    frames_root = extraction_root / "frames"
    shutil.rmtree(extraction_root, ignore_errors=True)
    decoded_root.mkdir(parents=True)
    shutil.copyfile(source, decoded_root / "failed.png")

    method = "auto"
    extract = run_command(
        [
            sys.executable,
            str(skill_dir / "scripts/extract_strip_frames.py"),
            "--decoded-dir",
            str(decoded_root),
            "--output-dir",
            str(frames_root),
            "--states",
            "failed",
            "--chroma-key",
            CHROMA_KEY,
            "--key-threshold",
            CHROMA_THRESHOLD,
            "--method",
            method,
        ]
    )
    if extract.returncode != 0:
        print(extract.stdout)
        print(extract.stderr, file=sys.stderr)
        return extract.returncode

    inspection_path = extraction_root / "review.json"
    inspection_arguments = [
        sys.executable,
        str(skill_dir / "scripts/inspect_frames.py"),
        "--frames-root",
        str(frames_root),
        "--json-out",
        str(inspection_path),
        "--states",
        "failed",
        "--require-components",
    ]
    inspection = run_command(inspection_arguments)
    inspection_result = json.loads(inspection_path.read_text(encoding="utf-8"))
    if (
        not inspection_result.get("ok")
        and args.allow_stable_slots
        and any(
            "used extraction method slots" in error
            for error in inspection_result.get("errors", [])
        )
    ):
        shutil.rmtree(frames_root, ignore_errors=True)
        method = "stable-slots"
        extract = run_command(
            [
                sys.executable,
                str(skill_dir / "scripts/extract_strip_frames.py"),
                "--decoded-dir",
                str(decoded_root),
                "--output-dir",
                str(frames_root),
                "--states",
                "failed",
                "--chroma-key",
                CHROMA_KEY,
                "--key-threshold",
                CHROMA_THRESHOLD,
                "--method",
                method,
            ]
        )
        if extract.returncode != 0:
            print(extract.stdout)
            print(extract.stderr, file=sys.stderr)
            return extract.returncode
        inspection_arguments.append("--allow-stable-slots")
        inspection = run_command(inspection_arguments)
        inspection_result = json.loads(inspection_path.read_text(encoding="utf-8"))

    if not inspection_result.get("ok"):
        print(json.dumps(inspection_result, ensure_ascii=False, indent=2))
        return inspection.returncode or 1

    extracted_paths = sorted((frames_root / "failed").glob("*.png"))
    if len(extracted_paths) != FRAME_COUNT:
        raise ValueError(
            f"{args.state}: expected {FRAME_COUNT} frames, got {len(extracted_paths)}"
        )
    output_frames = motion_root / "frames" / args.state
    shutil.rmtree(output_frames, ignore_errors=True)
    output_frames.mkdir(parents=True)
    frames: list[Image.Image] = []
    fragment_cleanup: list[dict[str, object]] = []
    for index, extracted in enumerate(extracted_paths):
        destination = output_frames / f"{index:02d}.png"
        shutil.copyfile(extracted, destination)
        fragment_cleanup.append(clean_frame(destination))
        with Image.open(destination) as opened:
            frame = opened.convert("RGBA")
        if frame.size != FRAME_SIZE:
            raise ValueError(
                f"{destination}: expected {FRAME_SIZE[0]}x{FRAME_SIZE[1]}, got "
                f"{frame.width}x{frame.height}"
            )
        frames.append(frame)

    render_contact_sheet(frames, qa_root / "contact-sheet.png")
    render_preview(frames, motion_root / "qa/previews" / f"{args.state}.gif")
    review = {
        "ok": True,
        "state": args.state,
        "frameCount": FRAME_COUNT,
        "frameSize": list(FRAME_SIZE),
        "extractionMethod": method,
        "inspection": inspection_result,
        "source": str(source),
        "frames": [str(path) for path in sorted(output_frames.glob("*.png"))],
        "warnings": inspection_result.get("warnings", []),
        "fragmentCleanup": fragment_cleanup,
    }
    (qa_root / "review.json").write_text(
        json.dumps(review, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    shutil.rmtree(extraction_root)
    print(json.dumps(review, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
