#!/usr/bin/env python3

"""Drive two independent HTTP clients through one real rendezvous process."""

from __future__ import annotations

import argparse
import base64
import json
import secrets
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    return parser.parse_args()


def post(base_url: str, path: str, body: dict[str, object]) -> dict[str, object]:
    request = urllib.request.Request(
        base_url.rstrip("/") + path,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            if response.status not in {200, 201}:
                raise RuntimeError(f"{path} returned HTTP {response.status}")
            return json.load(response)
    except urllib.error.HTTPError as error:
        payload = error.read().decode("utf-8", "replace")
        raise RuntimeError(f"{path} returned HTTP {error.code}: {payload}") from error


def credential(joined: dict[str, object], participant_id: str) -> dict[str, object]:
    return {"participant_id": participant_id, "nonce": joined["nonce"]}


def encounter_credential(
    joined: dict[str, object],
    participant_id: str,
    state: dict[str, object],
) -> dict[str, object]:
    return {
        **credential(joined, participant_id),
        "encounter_id": state["encounter_id"],
        "encounter_nonce": state["encounter_nonce"],
    }


def main() -> int:
    args = parse_args()
    suffix = secrets.token_hex(8)
    discovery_token = base64.b64encode(f"dual-client-{suffix}".encode("ascii")).decode("ascii")
    bodies: dict[str, dict[str, object]] = {}
    joined: dict[str, dict[str, object]] = {}
    for side, character in (("source", "penguin"), ("destination", "polar_bear")):
        participant_id = f"dual_client_{side}_{suffix}"
        body: dict[str, object] = {
            "participant_id": participant_id,
            "join_request_id": f"dual_join_{side}_{suffix}",
            "discovery_token": discovery_token,
            "public_card": {
                "schema_version": "public_pet_card_v1",
                "pet_name": "Mori" if side == "source" else "Nori",
                "character_id": character,
                "outfit_id": "star",
                "background_id": "sunset_coast",
                "social_state": "greeting",
            },
        }
        bodies[side] = body
        joined[side] = post(args.base_url, "/v1/sessions", body)

    states: dict[str, dict[str, object]] = {}
    auth: dict[str, dict[str, object]] = {}
    for side in ("source", "destination"):
        participant_id = str(bodies[side]["participant_id"])
        states[side] = post(
            args.base_url,
            f"/v1/sessions/{joined[side]['session_id']}/status",
            credential(joined[side], participant_id),
        )
        auth[side] = encounter_credential(
            joined[side],
            participant_id,
            states[side],
        )

    if states["source"].get("transfer_role") != "source":
        raise RuntimeError("first HTTP client was not assigned the source role")
    if states["destination"].get("transfer_role") != "destination":
        raise RuntimeError("second HTTP client was not assigned the destination role")

    for action in ("proximity-ready", "peer-card"):
        for side in ("source", "destination"):
            post(
                args.base_url,
                f"/v1/sessions/{joined[side]['session_id']}/{action}",
                auth[side],
            )

    first_confirmation = post(
        args.base_url,
        f"/v1/sessions/{joined['destination']['session_id']}/confirm",
        auth["destination"],
    )
    if first_confirmation.get("transfer_animation") is not None:
        raise RuntimeError("animation was released before bilateral confirmation")
    post(
        args.base_url,
        f"/v1/sessions/{joined['source']['session_id']}/confirm",
        auth["source"],
    )

    def fetch_final(side: str) -> tuple[str, dict[str, object]]:
        participant_id = str(bodies[side]["participant_id"])
        return (
            side,
            post(
                args.base_url,
                f"/v1/sessions/{joined[side]['session_id']}/status",
                credential(joined[side], participant_id),
            ),
        )

    # The real clients poll independently, so fetch their final cues in
    # parallel rather than charging one side for the other's network round trip.
    with ThreadPoolExecutor(max_workers=2) as executor:
        final = dict(executor.map(fetch_final, ("source", "destination")))

    source_cue = final["source"].get("transfer_animation")
    destination_cue = final["destination"].get("transfer_animation")
    if not isinstance(source_cue, dict) or not isinstance(destination_cue, dict):
        raise RuntimeError("both HTTP clients must receive a transfer cue")
    if source_cue["event_id"] != destination_cue["event_id"]:
        raise RuntimeError("A/B event IDs differ")
    if source_cue["starts_at"] != destination_cue["starts_at"]:
        raise RuntimeError("A/B start times differ")
    if source_cue["duration_ms"] != destination_cue["duration_ms"]:
        raise RuntimeError("A/B durations differ")
    if source_cue["role"] != "source" or destination_cue["role"] != "destination":
        raise RuntimeError("A/B roles are not opposite")
    projected_delays: dict[str, float] = {}
    for side, cue in (("source", source_cue), ("destination", destination_cue)):
        server_time = datetime.fromisoformat(str(final[side]["server_time"]).replace("Z", "+00:00"))
        starts_at = datetime.fromisoformat(str(cue["starts_at"]).replace("Z", "+00:00"))
        delay = (starts_at - server_time).total_seconds()
        projected_delays[side] = delay
        if not 0.75 <= delay <= 3.0:
            raise RuntimeError(
                f"{side} remaining delay {delay:.3f}s is outside the protocol bounds"
            )

    print(
        json.dumps(
            {
                "ok": True,
                "event_id": source_cue["event_id"],
                "starts_at": source_cue["starts_at"],
                "duration_ms": source_cue["duration_ms"],
                "source_role": source_cue["role"],
                "destination_role": destination_cue["role"],
                "projected_delay_seconds": {
                    side: round(delay, 3) for side, delay in projected_delays.items()
                },
            },
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
