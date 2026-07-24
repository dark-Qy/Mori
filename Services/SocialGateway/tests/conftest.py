from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from social_gateway.app import create_app
from social_gateway.audit import NullAuditSink
from social_gateway.config import GatewayConfig
from social_gateway.store import RendezvousStore


class ManualClock:
    def __init__(self) -> None:
        self.value = datetime(2026, 7, 23, 8, 0, tzinfo=timezone.utc)

    def __call__(self) -> datetime:
        return self.value

    def advance(self, seconds: int) -> None:
        self.value += timedelta(seconds=seconds)


@pytest.fixture
def config() -> GatewayConfig:
    return GatewayConfig(
        waiting_ttl_seconds=15,
        encounter_ttl_seconds=30,
        candidate_ttl_seconds=8,
        tombstone_ttl_seconds=5,
        proximity_window_seconds=5.0,
        transfer_animation_lead_seconds=1.25,
        transfer_animation_duration_ms=900,
        cleanup_interval_seconds=1.0,
        max_request_bytes=16_384,
        max_active_participants=20,
    )


@pytest.fixture
def clock() -> ManualClock:
    return ManualClock()


@pytest.fixture
def store(config, clock) -> RendezvousStore:
    return RendezvousStore(config, clock=clock)


@pytest.fixture
def client(config, store) -> TestClient:
    return TestClient(create_app(config=config, store=store, audit_sink=NullAuditSink()))


def token(label: str) -> str:
    return base64.b64encode(f"ni-token-{label}".encode("ascii")).decode("ascii")


def card(label: str) -> dict:
    return {
        "schema_version": "public_pet_card_v1",
        "pet_name": f"Pet {label}",
        "character_id": f"character-{label}",
        "outfit_id": f"outfit-{label}",
        "background_id": f"background-{label}",
        "social_state": "greeting",
    }


def join_body(
    label: str,
    *,
    participant_id: str | None = None,
    join_request_id: str | None = None,
) -> dict:
    return {
        "participant_id": participant_id or f"participant_{label}_opaque_123",
        "join_request_id": join_request_id or f"join_request_{label}_opaque_123",
        "discovery_token": token(label),
        "public_card": card(label),
    }


def credential(joined: dict, participant_id: str) -> dict:
    return {"participant_id": participant_id, "nonce": joined["nonce"]}


def encounter_credential(state: dict, joined: dict, participant_id: str) -> dict:
    assert state["encounter_id"] is not None
    assert state["encounter_nonce"] is not None
    return {
        "participant_id": participant_id,
        "nonce": joined["nonce"],
        "encounter_id": state["encounter_id"],
        "encounter_nonce": state["encounter_nonce"],
    }
