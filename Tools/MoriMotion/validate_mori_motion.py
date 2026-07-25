#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from PIL import Image


CHARACTER_ID = "penguin"
DEFERRED_CHARACTER_IDS = ("polar_bear",)
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
ASSET_ROOTS = (
    Path("Apps/Apple/WatchApp/Assets.xcassets/Characters"),
    Path("Apps/Apple/iPhoneApp/Assets.xcassets/Characters"),
)
CELL_SIZE = (192, 208)
FRAME_COUNT = 8


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate the finalized black Mori (penguin) G4 motion package."
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="Repository root (defaults to the root containing this tool).",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Return failure when integration warnings are present.",
    )
    return parser.parse_args()


def read_json(path: Path) -> Any:
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


def json_type_matches(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    return False


def resolve_ref(root_schema: dict[str, Any], reference: str) -> dict[str, Any]:
    if not reference.startswith("#/"):
        raise ValueError(f"unsupported non-local schema reference: {reference}")
    node: Any = root_schema
    for token in reference[2:].split("/"):
        node = node[token.replace("~1", "/").replace("~0", "~")]
    if not isinstance(node, dict):
        raise ValueError(f"schema reference is not an object: {reference}")
    return node


def schema_violations(
    value: Any,
    schema: dict[str, Any],
    root_schema: dict[str, Any],
    path: str = "$",
) -> list[str]:
    if "$ref" in schema:
        return schema_violations(value, resolve_ref(root_schema, schema["$ref"]), root_schema, path)

    violations: list[str] = []
    if "const" in schema and value != schema["const"]:
        violations.append(f"{path}: expected constant {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        violations.append(f"{path}: value {value!r} is not in the allowed enum")

    expected_type = schema.get("type")
    if expected_type and not json_type_matches(value, expected_type):
        return [f"{path}: expected {expected_type}, got {type(value).__name__}"]

    if isinstance(value, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in value:
                violations.append(f"{path}: missing required property {key!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in properties:
                    violations.append(f"{path}: unexpected property {key!r}")
        for key, child_schema in properties.items():
            if key in value:
                violations.extend(
                    schema_violations(value[key], child_schema, root_schema, f"{path}.{key}")
                )

    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            violations.append(f"{path}: expected at least {schema['minItems']} items")
        if schema.get("uniqueItems"):
            normalized = [json.dumps(item, sort_keys=True, separators=(",", ":")) for item in value]
            if len(set(normalized)) != len(normalized):
                violations.append(f"{path}: array items are not unique")
        prefix_items = schema.get("prefixItems", [])
        for index, child_schema in enumerate(prefix_items):
            if index < len(value):
                violations.extend(
                    schema_violations(value[index], child_schema, root_schema, f"{path}[{index}]")
                )
        items_schema = schema.get("items")
        if items_schema is False and len(value) > len(prefix_items):
            violations.append(f"{path}: unexpected items after index {len(prefix_items) - 1}")
        elif isinstance(items_schema, dict):
            start = len(prefix_items)
            for index in range(start, len(value)):
                violations.extend(
                    schema_violations(
                        value[index], items_schema, root_schema, f"{path}[{index}]"
                    )
                )

    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            violations.append(f"{path}: string is shorter than {schema['minLength']}")
        pattern = schema.get("pattern")
        if pattern and re.search(pattern, value) is None:
            violations.append(f"{path}: value does not match {pattern!r}")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            violations.append(f"{path}: value is below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            violations.append(f"{path}: value is above {schema['maximum']}")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            violations.append(f"{path}: value must be greater than {schema['exclusiveMinimum']}")

    if "oneOf" in schema:
        matches = sum(
            not schema_violations(value, option, root_schema, path)
            for option in schema["oneOf"]
        )
        if matches != 1:
            violations.append(f"{path}: expected exactly one oneOf branch, matched {matches}")
    return violations


@dataclass
class Report:
    strict: bool
    checks: dict[str, dict[str, Any]] = field(default_factory=dict)
    errors: list[dict[str, Any]] = field(default_factory=list)
    warnings: list[dict[str, Any]] = field(default_factory=list)

    def error(self, code: str, message: str, **context: Any) -> None:
        item = {"code": code, "message": message}
        if context:
            item["context"] = context
        self.errors.append(item)

    def warning(self, code: str, message: str, **context: Any) -> None:
        item = {"code": code, "message": message}
        if context:
            item["context"] = context
        self.warnings.append(item)

    def check(self, name: str, before_errors: int, **details: Any) -> None:
        self.checks[name] = {
            "ok": len(self.errors) == before_errors,
            **details,
        }

    def output(self, repo_root: Path) -> dict[str, Any]:
        passed = not self.errors and (not self.strict or not self.warnings)
        return {
            "ok": passed,
            "characterID": CHARACTER_ID,
            "scope": {
                "readyCharacters": [CHARACTER_ID],
                "deferredCharacters": list(DEFERRED_CHARACTER_IDS),
            },
            "strict": self.strict,
            "repoRoot": str(repo_root),
            "summary": {
                "checks": len(self.checks),
                "passedChecks": sum(check["ok"] for check in self.checks.values()),
                "errors": len(self.errors),
                "warnings": len(self.warnings),
            },
            "checks": self.checks,
            "errors": self.errors,
            "warnings": self.warnings,
        }


def safe_read_json(path: Path, report: Report, code: str) -> Any | None:
    try:
        return read_json(path)
    except FileNotFoundError:
        report.error(code, "required JSON file is missing", path=str(path))
    except json.JSONDecodeError as error:
        report.error(
            code,
            "required JSON file is invalid",
            path=str(path),
            line=error.lineno,
            column=error.colno,
        )
    return None


def standard_row_frames(character_root: Path, row: str) -> list[Path]:
    paths = sorted((character_root / "qa" / "rows" / row / "frames" / row).glob("*.png"))
    return [paths[index % len(paths)] for index in range(FRAME_COUNT)] if paths else []


def edge_alpha_pixels(image: Image.Image) -> int:
    alpha = image.getchannel("A")
    width, height = alpha.size
    boxes = (
        (0, 0, width, 1),
        (0, height - 1, width, height),
        (0, 0, 1, height),
        (width - 1, 0, width, height),
    )
    return sum(sum(alpha.crop(box).histogram()[1:]) for box in boxes)


def validate_catalog(
    repo_root: Path,
    catalog: dict[str, Any],
    schema: dict[str, Any],
    report: Report,
) -> dict[str, dict[str, Any]]:
    before = len(report.errors)
    violations = schema_violations(catalog, schema, schema)
    for violation in violations:
        report.error("catalog.schema", violation)
    report.check("catalogSchema", before, violationCount=len(violations), schemaVersion=2)

    before = len(report.errors)
    motions = catalog.get("motions", [])
    motion_ids = [motion.get("id") for motion in motions if isinstance(motion, dict)]
    if tuple(motion_ids) != MOTION_ORDER:
        report.error(
            "catalog.motion_ids",
            "catalog must contain the 16 G4 motion IDs in contract order",
            expected=list(MOTION_ORDER),
            actual=motion_ids,
        )
    if len(set(motion_ids)) != len(motion_ids):
        report.error("catalog.motion_ids", "motion IDs must be unique")

    definitions = {
        motion["id"]: motion
        for motion in motions
        if isinstance(motion, dict) and isinstance(motion.get("id"), str)
    }
    fallback = catalog.get("fallbackMotionID")
    fallback_definition = definitions.get(fallback)
    if fallback != "idle_neutral" or fallback_definition is None:
        report.error("catalog.fallback", "fallback must resolve to idle_neutral")
    elif (
        fallback_definition.get("source") != {"kind": "hatchV2Row", "id": "idle"}
        or fallback_definition.get("playback") != "loop"
    ):
        report.error(
            "catalog.fallback",
            "idle_neutral fallback must use the approved looping hatch v2 idle row",
        )
    defaults = catalog.get("defaults", {})
    if defaults.get("missingFramePolicy") != "fallbackToNeutralIdle":
        report.error(
            "catalog.fallback",
            "missing-frame policy must fall back to neutral idle",
        )

    priorities = catalog.get("priorityClasses", [])
    priority_ids = [item.get("id") for item in priorities if isinstance(item, dict)]
    priority_values = [item.get("priority") for item in priorities if isinstance(item, dict)]
    if len(set(priority_ids)) != len(priority_ids) or len(set(priority_values)) != len(
        priority_values
    ):
        report.error("catalog.priority", "priority class IDs and values must be unique")
    if priority_values != sorted(priority_values):
        report.error("catalog.priority", "priority values must be strictly ascending")
    known_priorities = set(priority_ids)

    layout_name = defaults.get("layoutPreset")
    layout = catalog.get("layoutPresets", {}).get(layout_name)
    if not isinstance(layout, dict):
        report.error("catalog.anchor", "default layout preset does not resolve")
    else:
        anchor = layout.get("anchor", {})
        if not (0 < anchor.get("x", -1) < 1 and 0 < anchor.get("footY", -1) < 1):
            report.error("catalog.anchor", "character anchor must be inside the sprite cell")
        if anchor.get("footY", 0) <= 0.5:
            report.error("catalog.anchor", "grounded foot anchor must be in the lower half")

    for motion_id, motion in definitions.items():
        if motion.get("priorityClass") not in known_priorities:
            report.error(
                "catalog.priority",
                "motion references an unknown priority class",
                motionID=motion_id,
            )
        expected_voice_over = f"motion.{motion_id}.voice_over"
        expected_visible = f"motion.{motion_id}.visible"
        if motion.get("voiceOverKey") != expected_voice_over:
            report.error(
                "catalog.voice_over",
                "VoiceOver key does not match motion ID",
                motionID=motion_id,
                expected=expected_voice_over,
            )
        if motion.get("visibleAlternateKey") != expected_visible:
            report.error(
                "catalog.voice_over",
                "visible alternate key does not match motion ID",
                motionID=motion_id,
                expected=expected_visible,
            )
        reduce_frame = motion.get("reduceMotionFrame")
        if not isinstance(reduce_frame, int) or not 0 <= reduce_frame < FRAME_COUNT:
            report.error(
                "catalog.reduce_motion",
                "Reduce Motion keyframe is outside the 8-frame clip",
                motionID=motion_id,
            )

    expected_touch = {"touch_head": ("head", "tap.head"), "touch_body": ("body", "tap.body")}
    for motion_id, (hit_test, trigger) in expected_touch.items():
        motion = definitions.get(motion_id, {})
        if (
            motion.get("hitTest") != hit_test
            or trigger not in motion.get("triggers", [])
            or motion.get("priorityClass") != "touch"
            or motion.get("playback") != "oneShot"
        ):
            report.error(
                "catalog.touch_area",
                "touch motion does not define its required hit area, trigger, priority, and playback",
                motionID=motion_id,
            )
    for motion_id, motion in definitions.items():
        if motion_id not in expected_touch and motion.get("hitTest") in {"head", "body"}:
            report.error(
                "catalog.touch_area",
                "non-touch motion claims a dedicated touch area",
                motionID=motion_id,
            )

    report.check(
        "catalogSemantics",
        before,
        motionCount=len(motion_ids),
        fallbackMotionID=fallback,
        priorityClassCount=len(priorities),
        reduceMotionDefined=len(definitions),
        voiceOverDefined=len(definitions),
        touchAreas=["head", "body"],
        anchor=layout.get("anchor") if isinstance(layout, dict) else None,
    )
    return definitions


def validate_aliases_and_poses(
    repo_root: Path,
    catalog: dict[str, Any],
    definitions: dict[str, dict[str, Any]],
    report: Report,
) -> None:
    before = len(report.errors)
    aliases = catalog.get("aliases", [])
    alias_ids = [item.get("id") for item in aliases if isinstance(item, dict)]
    if len(set(alias_ids)) != len(alias_ids):
        report.error("catalog.alias", "alias IDs must be unique")
    if set(alias_ids) & set(definitions):
        report.error("catalog.alias", "alias IDs must not collide with motion IDs")
    alias_map: dict[str, str] = {}
    for alias in aliases:
        alias_id = alias.get("id")
        target = alias.get("target", {})
        target_kind = target.get("kind")
        target_id = target.get("id")
        if target_kind == "motion":
            if target_id not in definitions:
                report.error(
                    "catalog.alias",
                    "motion alias target does not exist",
                    aliasID=alias_id,
                    targetID=target_id,
                )
            if target_id in alias_ids:
                alias_map[alias_id] = target_id
        elif target_kind == "hatchV2Row":
            row_root = (
                repo_root
                / "Design/WatchCompanionAssets/characters"
                / f"{CHARACTER_ID}-v2"
                / "qa"
                / "rows"
                / str(target_id)
            )
            if not row_root.is_dir():
                report.error(
                    "catalog.alias",
                    "hatch v2 alias target row does not exist",
                    aliasID=alias_id,
                    targetID=target_id,
                )
        else:
            report.error(
                "catalog.alias",
                "alias target kind is not supported",
                aliasID=alias_id,
                targetKind=target_kind,
            )

    for start in alias_map:
        seen: set[str] = set()
        current = start
        while current in alias_map:
            if current in seen:
                report.error(
                    "catalog.alias_cycle",
                    "alias cycle detected",
                    aliasID=start,
                )
                break
            seen.add(current)
            current = alias_map[current]

    for pose in catalog.get("poses", []):
        motion_id = pose.get("sourceMotionID")
        if motion_id is not None and motion_id not in definitions:
            report.error(
                "catalog.pose",
                "pose references an unknown motion",
                poseID=pose.get("id"),
                motionID=motion_id,
            )
    report.check(
        "aliasesAndPoses",
        before,
        aliasCount=len(aliases),
        poseCount=len(catalog.get("poses", [])),
        cycles=0 if len(report.errors) == before else None,
    )


def validate_forbidden_mappings(
    repo_root: Path,
    catalog: dict[str, Any],
    definitions: dict[str, dict[str, Any]],
    final_manifest: dict[str, Any],
    report: Report,
) -> None:
    before = len(report.errors)
    forbidden = catalog.get("forbiddenMappings", [])
    manifest_by_id = {
        motion.get("id"): motion
        for motion in final_manifest.get("motions", [])
        if isinstance(motion, dict)
    }
    for item in forbidden:
        motion_id = item.get("motionID")
        forbidden_source = item.get("forbiddenSource")
        definition_source = definitions.get(motion_id, {}).get("source", {}).get("id")
        if definition_source == forbidden_source:
            report.error(
                "catalog.forbidden_mapping",
                "catalog contains a forbidden placeholder mapping",
                motionID=motion_id,
                forbiddenSource=forbidden_source,
            )
        final_paths = manifest_by_id.get(motion_id, {}).get("frames", [])
        marker = f"/qa/rows/{forbidden_source}/"
        if any(marker in f"/{path}" for path in final_paths):
            report.error(
                "manifest.forbidden_mapping",
                "final motion frames contain a forbidden placeholder source",
                motionID=motion_id,
                forbiddenSource=forbidden_source,
            )

    runtime_map_path = (
        repo_root / "Design/WatchCompanionAssets/characters/runtime-state-map.json"
    )
    runtime_map = safe_read_json(runtime_map_path, report, "runtime_map.read")
    legacy_hits: list[dict[str, str]] = []
    if isinstance(runtime_map, dict):
        forbidden_pairs = {
            (item.get("motionID"), item.get("forbiddenSource")) for item in forbidden
        }
        for state in runtime_map.get("states", []):
            pair = (state.get("id"), state.get("sourceRow"))
            if pair in forbidden_pairs:
                legacy_hits.append(
                    {"motionID": str(pair[0]), "sourceRow": str(pair[1])}
                )
    if legacy_hits:
        report.warning(
            "integration.runtime_state_map_legacy_placeholders",
            "legacy runtime-state-map still references forbidden placeholder rows; migrate the runtime integration to motion-catalog/final assets",
            path=str(runtime_map_path.relative_to(repo_root)),
            mappings=legacy_hits,
        )
    report.check(
        "forbiddenMappings",
        before,
        catalogMappingCount=len(forbidden),
        finalPackageViolations=0 if len(report.errors) == before else None,
        legacyIntegrationWarnings=len(legacy_hits),
    )


def validate_foundation_and_manifests(
    repo_root: Path,
    catalog: dict[str, Any],
    definitions: dict[str, dict[str, Any]],
    authoring_manifest: dict[str, Any],
    final_manifest: dict[str, Any],
    final_validation: dict[str, Any],
    report: Report,
) -> None:
    before = len(report.errors)
    character_root = (
        repo_root / "Design/WatchCompanionAssets/characters" / f"{CHARACTER_ID}-v2"
    )
    foundation_path = character_root / "final" / "spritesheet-extended.png"
    if not foundation_path.is_file():
        report.error("foundation.missing", "approved v2 foundation atlas is missing")
        foundation_hash = None
    else:
        foundation_hash = sha256(foundation_path)
        recorded_hashes = {
            "authoringManifest": authoring_manifest.get("foundationAtlasSha256"),
            "finalManifest": final_manifest.get("foundationAtlasSha256"),
            "finalValidation": final_validation.get("foundationAtlasSha256"),
        }
        for source, recorded_hash in recorded_hashes.items():
            if recorded_hash != foundation_hash:
                report.error(
                    "foundation.hash",
                    "approved v2 foundation atlas hash changed",
                    source=source,
                    expected=recorded_hash,
                    actual=foundation_hash,
                )

    if authoring_manifest.get("characterID") != CHARACTER_ID:
        report.error("manifest.character", "authoring manifest character is not penguin")
    jobs = authoring_manifest.get("jobs", [])
    expected_product_ids = set(MOTION_ORDER) - {"idle_neutral"}
    job_ids = {job.get("id") for job in jobs}
    if job_ids != expected_product_ids or len(jobs) != len(expected_product_ids):
        report.error(
            "manifest.jobs",
            "authoring manifest must contain exactly the 15 product motions",
        )
    incomplete = sorted(
        str(job.get("id")) for job in jobs if job.get("status") != "complete"
    )
    if incomplete:
        report.error(
            "manifest.jobs",
            "product-motion jobs are incomplete",
            motionIDs=incomplete,
        )

    if (
        final_manifest.get("characterID") != CHARACTER_ID
        or final_manifest.get("status") != "ready"
        or final_manifest.get("frameCount") != FRAME_COUNT
        or final_manifest.get("cell") != {"width": CELL_SIZE[0], "height": CELL_SIZE[1]}
    ):
        report.error(
            "manifest.final_contract",
            "final penguin manifest is not a ready 8-frame 192x208 package",
        )
    final_motions = final_manifest.get("motions", [])
    final_ids = [motion.get("id") for motion in final_motions]
    if tuple(final_ids) != MOTION_ORDER:
        report.error(
            "manifest.motion_ids",
            "final manifest does not contain the 16 G4 motions in contract order",
            actual=final_ids,
        )
    for motion in final_motions:
        motion_id = motion.get("id")
        definition = definitions.get(motion_id)
        if definition is None:
            continue
        expected_source = definition.get("source", {}).get("kind")
        expected_assets = [
            f"character_{CHARACTER_ID}_{motion_id}_{index:02d}"
            for index in range(FRAME_COUNT)
        ]
        if (
            motion.get("sourceKind") != expected_source
            or motion.get("playback") != definition.get("playback")
            or motion.get("framesPerSecond")
            != catalog.get("defaults", {}).get("framesPerSecond")
            or motion.get("reduceMotionFrame") != definition.get("reduceMotionFrame")
            or motion.get("assetNames") != expected_assets
            or len(motion.get("frames", [])) != FRAME_COUNT
        ):
            report.error(
                "manifest.motion_contract",
                "final motion metadata does not match the catalog",
                motionID=motion_id,
            )
    if (
        final_validation.get("ok") is not True
        or final_validation.get("characterID") != CHARACTER_ID
        or final_validation.get("motionCount") != len(MOTION_ORDER)
        or final_validation.get("errors")
    ):
        report.error(
            "manifest.final_validation",
            "recorded final validation is not a clean penguin pass",
        )
    report.check(
        "foundationAndManifests",
        before,
        foundationAtlasSha256=foundation_hash,
        authoringJobs=len(jobs),
        finalStatus=final_manifest.get("status"),
        motionCount=len(final_motions),
    )


def validate_frames(
    repo_root: Path,
    final_manifest: dict[str, Any],
    report: Report,
) -> None:
    before = len(report.errors)
    character_root = (
        repo_root / "Design/WatchCompanionAssets/characters" / f"{CHARACTER_ID}-v2"
    )
    sequence_hashes: dict[str, str] = {}
    edge_touch_count = 0
    verified_frame_count = 0
    manifest_motions = final_manifest.get("motions", [])

    for motion in manifest_motions:
        motion_id = motion.get("id")
        paths = [repo_root / value for value in motion.get("frames", [])]
        expected_names = [f"{index:02d}.png" for index in range(FRAME_COUNT)]
        if motion_id != "idle_neutral" and [path.name for path in paths] != expected_names:
            report.error(
                "frames.names",
                "motion frame names must be 00.png through 07.png",
                motionID=motion_id,
            )
        if len(paths) != FRAME_COUNT:
            continue
        missing = [str(path.relative_to(repo_root)) for path in paths if not path.is_file()]
        if missing:
            report.error(
                "frames.missing",
                "motion frame files are missing",
                motionID=motion_id,
                paths=missing,
            )
            continue
        for index, path in enumerate(paths):
            try:
                with Image.open(path) as opened:
                    image = opened.convert("RGBA")
            except Exception as error:
                report.error(
                    "frames.unreadable",
                    "motion frame is unreadable",
                    motionID=motion_id,
                    frame=index,
                    error=str(error),
                )
                continue
            verified_frame_count += 1
            if image.size != CELL_SIZE:
                report.error(
                    "frames.dimensions",
                    "motion frame must be 192x208",
                    motionID=motion_id,
                    frame=index,
                    actual=list(image.size),
                )
            touching = edge_alpha_pixels(image)
            if touching:
                edge_touch_count += 1
                report.error(
                    "frames.edge_touch",
                    "non-transparent pixels touch the frame boundary",
                    motionID=motion_id,
                    frame=index,
                    pixels=touching,
                )
        digest = sequence_sha256(paths)
        sequence_hashes[str(motion_id)] = digest
        if motion.get("sequenceSha256") != digest:
            report.error(
                "frames.sequence_hash",
                "motion sequence hash does not match final manifest",
                motionID=motion_id,
                expected=motion.get("sequenceSha256"),
                actual=digest,
            )

    product_hashes = {
        motion_id: digest
        for motion_id, digest in sequence_hashes.items()
        if motion_id != "idle_neutral"
    }
    if len(product_hashes) != 15 or len(set(product_hashes.values())) != 15:
        report.error(
            "frames.product_uniqueness",
            "the 15 product clips must have distinct frame sequences",
        )

    canonical_hashes: dict[str, str] = {}
    for row in CANONICAL_ROWS:
        paths = standard_row_frames(character_root, row)
        if not paths:
            report.error(
                "frames.foundation_row",
                "approved hatch v2 row is missing",
                row=row,
            )
            continue
        canonical_hashes[row] = sequence_sha256(paths)
    for motion_id, digest in product_hashes.items():
        matching_rows = [
            row for row, canonical_digest in canonical_hashes.items() if canonical_digest == digest
        ]
        if matching_rows:
            report.error(
                "frames.standard_placeholder",
                "dedicated product clip duplicates a standard hatch v2 row",
                motionID=motion_id,
                rows=matching_rows,
            )

    report.check(
        "frameIntegrity",
        before,
        verifiedFrames=verified_frame_count,
        cell={"width": CELL_SIZE[0], "height": CELL_SIZE[1]},
        edgeTouchFrames=edge_touch_count,
        distinctProductClips=len(set(product_hashes.values())),
        standardRowsCompared=len(canonical_hashes),
    )


def expected_contents(filename: str) -> dict[str, Any]:
    return {
        "images": [{"filename": filename, "idiom": "universal", "scale": "1x"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": False},
    }


def validate_installation(
    repo_root: Path,
    final_manifest: dict[str, Any],
    receipt: dict[str, Any],
    report: Report,
) -> None:
    before = len(report.errors)
    expected_records: list[dict[str, Any]] = []
    installed_byte_count = 0
    for asset_root_relative in ASSET_ROOTS:
        for motion in final_manifest.get("motions", []):
            for source_value, asset_name in zip(
                motion.get("frames", []), motion.get("assetNames", [])
            ):
                source = repo_root / source_value
                image_set = repo_root / asset_root_relative / f"{asset_name}.imageset"
                filename = f"{asset_name}.png"
                destination = image_set / filename
                contents_path = image_set / "Contents.json"
                if not source.is_file() or not destination.is_file():
                    report.error(
                        "install.asset_missing",
                        "source or installed asset is missing",
                        catalog=str(asset_root_relative),
                        assetName=asset_name,
                    )
                    continue
                source_bytes = source.read_bytes()
                destination_bytes = destination.read_bytes()
                if destination_bytes != source_bytes:
                    report.error(
                        "install.byte_mismatch",
                        "installed asset bytes differ from source",
                        catalog=str(asset_root_relative),
                        assetName=asset_name,
                    )
                else:
                    installed_byte_count += 1
                contents = safe_read_json(contents_path, report, "install.contents")
                if contents is not None and contents != expected_contents(filename):
                    report.error(
                        "install.contents",
                        "imageset Contents.json does not match the installed file",
                        catalog=str(asset_root_relative),
                        assetName=asset_name,
                    )
                expected_records.append(
                    {
                        "catalog": str(asset_root_relative),
                        "assetName": asset_name,
                        "source": source_value,
                        "sha256": hashlib.sha256(destination_bytes).hexdigest(),
                    }
                )

    if (
        receipt.get("schemaVersion") != 1
        or receipt.get("characterID") != CHARACTER_ID
        or receipt.get("catalogCount") != len(ASSET_ROOTS)
        or receipt.get("motionCount") != len(MOTION_ORDER)
        or receipt.get("frameCount") != len(expected_records)
        or receipt.get("installed") != expected_records
    ):
        report.error(
            "install.receipt",
            "install receipt does not exactly match both asset catalogs",
            expectedRecords=len(expected_records),
            actualRecords=len(receipt.get("installed", [])),
        )
    report.check(
        "assetInstallation",
        before,
        catalogs=[str(path) for path in ASSET_ROOTS],
        expectedAssets=len(expected_records),
        byteIdenticalAssets=installed_byte_count,
        receiptMatches=len(report.errors) == before,
    )


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    report = Report(strict=args.strict)
    characters_root = repo_root / "Design/WatchCompanionAssets/characters"
    product_root = characters_root / f"{CHARACTER_ID}-v2" / "product-motion"

    catalog = safe_read_json(
        characters_root / "motion-catalog.json", report, "catalog.read"
    )
    schema = safe_read_json(
        characters_root / "motion-catalog.schema.json", report, "catalog.schema_read"
    )
    authoring_manifest = safe_read_json(
        product_root / "manifest.json", report, "manifest.authoring_read"
    )
    final_manifest = safe_read_json(
        product_root / "final/motion-manifest.json", report, "manifest.final_read"
    )
    final_validation = safe_read_json(
        product_root / "final/validation.json", report, "manifest.validation_read"
    )
    receipt = safe_read_json(
        product_root / "final/install-receipt.json", report, "install.receipt_read"
    )

    required = (
        catalog,
        schema,
        authoring_manifest,
        final_manifest,
        final_validation,
        receipt,
    )
    if all(isinstance(item, dict) for item in required):
        definitions = validate_catalog(repo_root, catalog, schema, report)
        validate_aliases_and_poses(repo_root, catalog, definitions, report)
        validate_foundation_and_manifests(
            repo_root,
            catalog,
            definitions,
            authoring_manifest,
            final_manifest,
            final_validation,
            report,
        )
        validate_forbidden_mappings(
            repo_root, catalog, definitions, final_manifest, report
        )
        validate_frames(repo_root, final_manifest, report)
        validate_installation(repo_root, final_manifest, receipt, report)

    output = report.output(repo_root)
    print(json.dumps(output, ensure_ascii=False, indent=2))
    return 0 if output["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
