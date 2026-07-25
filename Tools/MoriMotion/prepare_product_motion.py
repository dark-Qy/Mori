#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


STYLE = (
    "Pet-safe pixel-art-adjacent digital mascot: compact full-body humanoid silhouette, simple "
    "dark outline, limited stable palette, flat cel shading, visible stepped edges, expressive "
    "face, and crisp opaque boundaries suitable for a 192x208 sprite cell."
)

COMMON_CLEAN_EXTRACTION = (
    "Crisp opaque edges and generous safe padding. No scenery, text, UI, frame labels, guide "
    "marks, checkerboard, shadows, glows, blur, smears, speed lines, dust, floor marks, detached "
    "effects, stray pixels, or chroma-key colors inside the character."
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepare deterministic Mori product-motion jobs.")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--character", required=True, choices=("penguin", "polar_bear"))
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_text(path: Path, value: str, force: bool) -> None:
    if path.exists() and not force:
        raise FileExistsError(f"{path} already exists; pass --force to regenerate")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


def write_json(path: Path, value: object, force: bool) -> None:
    write_text(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n", force)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def prompt_for(
    *,
    character_id: str,
    identity: str,
    chroma_key: str,
    action: dict[str, Any],
) -> str:
    requirements = "\n".join(f"- {item}" for item in action["requirements"])
    return f"""Create one horizontal product animation strip for Mori character `{character_id}`, motion `{action["id"]}`.

Use the attached canonical base, original character reference, and approved v2 contact sheet only to preserve identity. Use the attached eight-slot layout guide only for slot count, spacing, centering, and padding; do not draw or copy the guide.

Output exactly 8 complete full-body poses in one left-to-right row on a perfectly flat pure {chroma_key} chroma-key background. Treat the row as eight invisible equal-width slots: one centered complete pose per slot, evenly spaced, with no overlap, clipping, empty slot, label, border, or visible grid.

Identity lock: {identity} Preserve the same face, hair, proportions, costume construction, markings, palette, material, silhouette, and personality in every frame. Never blend in the other Mori character and never redesign the costume.

Style: {STYLE}

Sequence type: {action["sequenceType"]}.
Motion: {action["action"]}

Motion requirements:
{requirements}

Continuity: keep apparent character scale, foot baseline, body proportions, and registration stable unless the authored action itself changes body height. Every adjacent frame must advance the same single motion. Loops must close naturally; one-shots must read chronologically from frame 00 to frame 07.

Background: exactly one uniform {chroma_key} color with no gradient, texture, reflection, floor plane, lighting variation, or shadow. Do not use {chroma_key} anywhere inside the character.

Clean extraction: {COMMON_CLEAN_EXTRACTION}
"""


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    character_root = (
        repo_root / "Design/WatchCompanionAssets/characters" / f"{args.character}-v2"
    )
    request = read_json(character_root / "pet_request.json")
    actions = read_json(
        repo_root / "Design/WatchCompanionAssets/characters/product-motion-actions.json"
    )
    motion_catalog = read_json(
        repo_root / "Design/WatchCompanionAssets/characters/motion-catalog.json"
    )

    product_ids = {
        motion["id"]
        for motion in motion_catalog["motions"]
        if motion["source"]["kind"] == "productClip"
    }
    action_ids = {action["id"] for action in actions["actions"]}
    if product_ids != action_ids:
        missing = sorted(product_ids - action_ids)
        extra = sorted(action_ids - product_ids)
        raise ValueError(f"action/catalog mismatch; missing={missing}, extra={extra}")

    chroma_key = request["chroma_key"]["hex"]
    identity = request["pet_notes"]
    output_root = character_root / "product-motion"
    references = [
        {
            "path": "../references/reference-01.png",
            "role": "original character identity reference",
        },
        {
            "path": "../references/canonical-base.png",
            "role": "canonical identity reference",
        },
        {
            "path": "../qa/contact-sheet-extended.png",
            "role": "approved v2 identity and scale reference",
        },
        {
            "path": "../references/layout-guides/running-right.png",
            "role": "eight-slot layout guide only; do not copy guide pixels",
        },
    ]

    jobs: list[dict[str, Any]] = []
    for action in actions["actions"]:
        prompt_path = output_root / "prompts" / f"{action['id']}.md"
        write_text(
            prompt_path,
            prompt_for(
                character_id=args.character,
                identity=identity,
                chroma_key=chroma_key,
                action=action,
            ),
            args.force,
        )
        jobs.append(
            {
                "id": action["id"],
                "status": "pending",
                "sequenceType": action["sequenceType"],
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
        "frameCount": actions["frameCount"],
        "generationTool": "built-in image_gen (Image2)",
        "foundationAtlas": "../final/spritesheet-extended.png",
        "foundationAtlasSha256": sha256(
            character_root / "final" / "spritesheet-extended.png"
        ),
        "status": "authoring",
        "jobs": jobs,
    }
    write_json(output_root / "manifest.json", manifest, args.force)
    print(
        json.dumps(
            {
                "ok": True,
                "character": args.character,
                "jobs": len(jobs),
                "output": str(output_root),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
