import logging

import pytest
from conftest import join_body
from fastapi.testclient import TestClient

from social_gateway.app import create_app
from social_gateway.audit import StructuredAuditSink
from social_gateway.config import GatewayConfig
from social_gateway.store import RendezvousStore


def test_audit_log_never_contains_participant_token_nonce_or_card(caplog, config, clock) -> None:
    caplog.set_level(logging.INFO, logger="social_gateway.audit")
    store = RendezvousStore(config, clock=clock)
    client = TestClient(create_app(config=config, store=store, audit_sink=StructuredAuditSink()))
    body = join_body("uniquely-sensitive")

    response = client.post("/v1/sessions", json=body)

    assert response.status_code == 201
    assert "social_rendezvous" in caplog.text
    assert body["participant_id"] not in caplog.text
    assert body["discovery_token"] not in caplog.text
    assert body["public_card"]["pet_name"] not in caplog.text
    assert response.json()["nonce"] not in caplog.text


def test_configuration_reads_bounded_environment_values() -> None:
    config = GatewayConfig.from_environment(
        {
            "SOCIAL_WAITING_TTL_SECONDS": "20",
            "SOCIAL_ENCOUNTER_TTL_SECONDS": "90",
            "SOCIAL_CANDIDATE_TTL_SECONDS": "9",
            "SOCIAL_TOMBSTONE_TTL_SECONDS": "10",
            "SOCIAL_PROXIMITY_WINDOW_SECONDS": "4.5",
            "SOCIAL_CLEANUP_INTERVAL_SECONDS": "0.25",
            "SOCIAL_MAX_REQUEST_BYTES": "8192",
            "SOCIAL_MAX_ACTIVE_PARTICIPANTS": "50",
        }
    )

    assert config == GatewayConfig(
        waiting_ttl_seconds=20,
        encounter_ttl_seconds=90,
        candidate_ttl_seconds=9,
        tombstone_ttl_seconds=10,
        proximity_window_seconds=4.5,
        cleanup_interval_seconds=0.25,
        max_request_bytes=8192,
        max_active_participants=50,
    )


@pytest.mark.parametrize(
    "environment",
    [
        {"SOCIAL_WAITING_TTL_SECONDS": "1"},
        {"SOCIAL_ENCOUNTER_TTL_SECONDS": "1000"},
        {"SOCIAL_CANDIDATE_TTL_SECONDS": "2"},
        {"SOCIAL_TOMBSTONE_TTL_SECONDS": "1"},
        {"SOCIAL_PROXIMITY_WINDOW_SECONDS": "0.5"},
        {"SOCIAL_PROXIMITY_WINDOW_SECONDS": "not-a-number"},
        {"SOCIAL_CLEANUP_INTERVAL_SECONDS": "0"},
        {"SOCIAL_MAX_REQUEST_BYTES": "100"},
        {"SOCIAL_MAX_ACTIVE_PARTICIPANTS": "1"},
        {"SOCIAL_WAITING_TTL_SECONDS": "not-an-int"},
    ],
)
def test_invalid_configuration_is_rejected(environment) -> None:
    with pytest.raises(ValueError):
        GatewayConfig.from_environment(environment)


def test_capacity_limit_fails_closed(clock) -> None:
    config = GatewayConfig(max_active_participants=2)
    store = RendezvousStore(config, clock=clock)
    client = TestClient(create_app(config=config, store=store))
    first = client.post("/v1/sessions", json=join_body("one"))
    second = client.post("/v1/sessions", json=join_body("two"))

    # A matched candidate pair still consumes the global active cap.
    third = client.post("/v1/sessions", json=join_body("three"))

    assert first.status_code == 201
    assert second.status_code == 201
    assert third.status_code == 503
    assert third.json()["error"]["code"] == "capacity_reached"
