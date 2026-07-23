import time

from conftest import join_body
from fastapi.testclient import TestClient

from social_gateway.app import create_app
from social_gateway.audit import NullAuditSink
from social_gateway.config import GatewayConfig
from social_gateway.store import RendezvousStore


def test_lifespan_cleanup_erases_and_purges_without_another_request(clock) -> None:
    config = GatewayConfig(
        waiting_ttl_seconds=15,
        encounter_ttl_seconds=30,
        candidate_ttl_seconds=8,
        tombstone_ttl_seconds=5,
        proximity_window_seconds=5.0,
        cleanup_interval_seconds=0.01,
        max_request_bytes=16_384,
        max_active_participants=20,
    )
    store = RendezvousStore(config, clock=clock)
    app = create_app(config=config, store=store, audit_sink=NullAuditSink())

    with TestClient(app) as client:
        first_body = join_body("background-cleanup-a")
        second_body = join_body("background-cleanup-b")
        first = client.post("/v1/sessions", json=first_body).json()
        second = client.post("/v1/sessions", json=second_body).json()
        session_ids = (first["session_id"], second["session_id"])
        idempotency_keys = (
            (first_body["participant_id"], first_body["join_request_id"]),
            (second_body["participant_id"], second_body["join_request_id"]),
        )
        clock.advance(31)

        deadline = time.monotonic() + 0.5
        while (
            store._sessions[session_ids[0]].discovery_token is not None
            and time.monotonic() < deadline
        ):
            time.sleep(0.005)

        for session_id in session_ids:
            assert store._sessions[session_id].status.value == "expired"
            assert store._sessions[session_id].discovery_token is None
            assert store._sessions[session_id].public_card is None
        for idempotency_key in idempotency_keys:
            assert store._idempotency[idempotency_key].response.peer_discovery_token is None

        clock.advance(6)
        deadline = time.monotonic() + 0.5
        while session_ids[0] in store._sessions and time.monotonic() < deadline:
            time.sleep(0.005)

        for session_id in session_ids:
            assert session_id not in store._sessions
        for idempotency_key in idempotency_keys:
            retained = store._idempotency[idempotency_key]
            assert retained.response is not None
            assert retained.response.status.value == "expired"
            assert retained.response.peer_discovery_token is None


def test_lifespan_rotates_candidates_without_a_followup_request(clock) -> None:
    config = GatewayConfig(
        waiting_ttl_seconds=15,
        encounter_ttl_seconds=30,
        candidate_ttl_seconds=8,
        tombstone_ttl_seconds=5,
        proximity_window_seconds=5.0,
        cleanup_interval_seconds=0.01,
        max_request_bytes=16_384,
        max_active_participants=20,
    )
    store = RendezvousStore(config, clock=clock)
    app = create_app(config=config, store=store, audit_sink=NullAuditSink())

    with TestClient(app) as client:
        joined = [
            client.post("/v1/sessions", json=join_body(label)).json()
            for label in ("rotate-a", "rotate-b", "rotate-c", "rotate-d")
        ]
        old_encounters = set(store._encounters)
        assert len(old_encounters) == 2
        clock.advance(9)

        deadline = time.monotonic() + 0.5
        while set(store._encounters) == old_encounters and time.monotonic() < deadline:
            time.sleep(0.005)

        assert len(store._encounters) == 2
        assert set(store._encounters).isdisjoint(old_encounters)
        assert {store._sessions[item["session_id"]].nonce for item in joined} == {
            item["nonce"] for item in joined
        }
