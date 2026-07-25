#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


ACTIONS = (
    {
        "id": "touch_head",
        "sequence": (
            "Frame 00 starts in the approved neutral stance. Frame 01 dips the head slightly. "
            "Frames 02-04 close the eyes into a warm happy expression with a tiny head lean and "
            "subtle hair follow-through. Frames 05-07 reopen the eyes and settle smoothly back "
            "to the exact neutral stance."
        ),
        "requirements": (
            "The reaction must read as enjoying a gentle head pat without drawing an external hand.",
            "Keep both feet planted and the lower body registered to one stable baseline.",
            "Put the emotional peak in frames 02-04 so it is visible during the Watch 850ms response.",
            "No waving, jumping, floating hearts, sparkles, motion marks, or detached effects.",
        ),
    },
    {
        "id": "touch_body",
        "sequence": (
            "Frame 00 starts in the approved neutral stance. Frame 01 shows a tiny surprised blink. "
            "Frames 02-04 turn the head and upper torso slightly toward the touch, then lean closer "
            "with a friendly smile. Frames 05-07 relax and return smoothly to the exact neutral stance."
        ),
        "requirements": (
            "The reaction must read as noticing a light body touch and choosing to turn closer.",
            "Keep the motion compact: no full spin, fall, failure pose, or large lateral travel.",
            "Keep both feet planted and put the readable peak in frames 02-04.",
            "No external hand, punctuation, impact mark, dust, shadow, or detached effect.",
        ),
    },
    {
        "id": "social_leap",
        "sequence": (
            "Frame 00 starts in the approved neutral stance. Frames 01-02 anticipate with a small "
            "crouch. Frames 03-05 make a cheerful upward-forward leap using body height and limb "
            "poses only. Frames 06-07 land and finish in a stable friendly stance."
        ),
        "requirements": (
            "The eight poses are a chronological one-shot used during cross-Watch pet transfer.",
            "Show the leap only through pose and vertical position; keep the character identity intact.",
            "No floor, landing mark, dust, speed line, motion trail, shadow, or detached effect.",
            "Frame 07 must be a clean landed pose suitable for holding at the end of transfer.",
        ),
    },
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Prepare grounded runtime interaction-motion jobs for one character."
    )
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--character", required=True)
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_text(path: Path, value: str, force: bool) -> None:
    if path.exists() and not force:
        raise FileExistsError(f"{path} already exists; pass --force to regenerate")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


def prompt(
    *,
    character_id: str,
    identity: str,
    chroma_key: str,
    action: dict[str, Any],
) -> str:
    requirements = "\n".join(f"- {item}" for item in action["requirements"])
    return f"""Create one horizontal runtime animation strip for character `{character_id}`, action `{action["id"]}`.

Use the attached original reference, canonical base, approved idle strip, and eight-slot layout guide. The guide is for spacing only; do not copy its pixels, boxes, labels, or marks.

Output exactly 8 complete full-body poses in one left-to-right row on a perfectly flat pure {chroma_key} chroma-key background. Treat the row as eight invisible equal-width slots: one centered complete pose per slot, evenly spaced, with no overlap, clipping, empty slot, label, border, or visible grid.

Identity lock: {identity}

Style: crisp hand-placed pixel art with hard square pixels, a limited stable palette, simple dark outlines, flat two-tone shading, and no antialiasing. Preserve the exact face, hair, proportions, costume, accessories, colors, silhouette, and personality in every frame.

Motion: {action["sequence"]}

Requirements:
{requirements}

Continuity: keep apparent scale, foot baseline, body proportions, and registration stable unless the authored action explicitly changes body height. Every adjacent frame advances the same motion. Frame 00 and the final settled frame must remain identity-consistent with the canonical base.

Background: exactly one uniform {chroma_key} color with no gradient, texture, reflection, floor plane, lighting variation, or shadow. Never use {chroma_key} inside the character.

Avoid: scenery, text, UI, frame numbers, guide marks, checkerboard, shadows, glow, blur, smears, extra characters, extra limbs, detached effects, stray pixels, or cropped body parts.
"""


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    run_slug = args.character.replace("_", "-")
    run_dir = repo_root / "Design/WatchCompanionAssets/characters" / f"{run_slug}-v2"
    request = read_json(run_dir / "pet_request.json")
    chroma_key = request["chroma_key"]["hex"]
    output_root = run_dir / "product-motion"
    references = [
        {
            "path": "../references/reference-01.png",
            "role": "accepted pixel identity reference",
        },
        {
            "path": "../references/canonical-base.png",
            "role": "canonical identity reference",
        },
        {
            "path": "../decoded/idle.png",
            "role": "approved idle identity, scale, and baseline reference",
        },
        {
            "path": "../references/layout-guides/running-right.png",
            "role": "eight-slot layout guide only; do not copy guide pixels",
        },
    ]
    jobs = []
    for action in ACTIONS:
        prompt_path = output_root / "prompts" / f"{action['id']}.md"
        write_text(
            prompt_path,
            prompt(
                character_id=args.character,
                identity=request["pet_notes"],
                chroma_key=chroma_key,
                action=action,
            ),
            args.force,
        )
        jobs.append(
            {
                "id": action["id"],
                "status": "pending",
                "promptFile": f"prompts/{action['id']}.md",
                "inputImages": references,
                "outputPath": f"decoded/{action['id']}.png",
                "sourcePath": None,
                "completedAt": None,
            }
        )

    manifest = {
        "schemaVersion": 1,
        "characterID": args.character,
        "chromaKey": chroma_key,
        "frameCount": 8,
        "framesPerSecond": 6,
        "generationSkill": "$imagegen",
        "jobs": jobs,
    }
    write_text(
        output_root / "manifest.json",
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        args.force,
    )
    print(
        json.dumps(
            {
                "ok": True,
                "character": args.character,
                "jobs": len(jobs),
                "output": str(output_root),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
