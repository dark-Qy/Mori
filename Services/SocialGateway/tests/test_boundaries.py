import base64
from copy import deepcopy

import pytest
from conftest import join_body


@pytest.mark.parametrize(
    "mutation",
    [
        lambda body: body.update({"unexpected": "private-value"}),
        lambda body: body["public_card"].update({"health_summary": "private-health"}),
        lambda body: body.update({"participant_id": "too-short"}),
        lambda body: body.update({"participant_id": "invalid participant identifier"}),
        lambda body: body.update({"join_request_id": "too-short"}),
        lambda body: body.update({"discovery_token": "not base64 !!!"}),
        lambda body: body["public_card"].update({"pet_name": "bad\nname"}),
        lambda body: body["public_card"].update({"character_id": "../escape"}),
        lambda body: body["public_card"].update({"schema_version": "future-card"}),
        lambda body: body["public_card"].update({"social_state": "medical_distress"}),
    ],
)
def test_strict_schema_rejects_unknown_or_invalid_data_without_echo(client, mutation) -> None:
    body = deepcopy(join_body("strict"))
    mutation(body)

    response = client.post("/v1/sessions", json=body)

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_request"
    assert "private-value" not in response.text
    assert "private-health" not in response.text
    assert response.headers["cache-control"] == "no-store"


def test_decoded_discovery_token_size_is_bounded(client) -> None:
    body = join_body("oversized-token")
    body["discovery_token"] = base64.b64encode(b"x" * 2_049).decode("ascii")

    response = client.post("/v1/sessions", json=body)

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_request"


def test_request_byte_limit_is_applied_before_json_validation(config, store) -> None:
    from fastapi.testclient import TestClient

    from social_gateway.app import create_app
    from social_gateway.audit import NullAuditSink
    from social_gateway.config import GatewayConfig

    tiny_config = GatewayConfig(
        waiting_ttl_seconds=config.waiting_ttl_seconds,
        encounter_ttl_seconds=config.encounter_ttl_seconds,
        candidate_ttl_seconds=config.candidate_ttl_seconds,
        tombstone_ttl_seconds=config.tombstone_ttl_seconds,
        max_request_bytes=200,
        max_active_participants=config.max_active_participants,
    )
    app = create_app(config=tiny_config, store=store, audit_sink=NullAuditSink())

    response = TestClient(app).post("/v1/sessions", json=join_body("large"))

    assert response.status_code == 413
    assert response.json()["error"]["code"] == "request_too_large"
    assert response.headers["cache-control"] == "no-store"


def test_non_json_content_type_is_rejected(client) -> None:
    response = client.post(
        "/v1/sessions",
        content="private-token-or-card",
        headers={"content-type": "text/plain"},
    )

    assert response.status_code == 415
    assert response.json()["error"]["code"] == "unsupported_media_type"
    assert "private-token-or-card" not in response.text


def test_session_path_is_strictly_bounded(client) -> None:
    body = join_body("path")
    joined = client.post("/v1/sessions", json=body).json()
    auth = {"participant_id": body["participant_id"], "nonce": joined["nonce"]}

    for invalid_session_id in ("short", "g" * 32, "a" * 33):
        response = client.post(
            f"/v1/sessions/{invalid_session_id}/status",
            json=auth,
        )
        assert response.status_code == 422
        assert response.json()["error"]["code"] == "invalid_request"


def test_candidate_actions_require_an_encounter_generation(client) -> None:
    first_body = join_body("generation-a")
    first = client.post("/v1/sessions", json=first_body).json()
    client.post("/v1/sessions", json=join_body("generation-b"))
    session_only = {
        "participant_id": first_body["participant_id"],
        "nonce": first["nonce"],
    }

    for endpoint in ("proximity-ready", "peer-card", "confirm"):
        response = client.post(
            f"/v1/sessions/{first['session_id']}/{endpoint}",
            json=session_only,
        )
        assert response.status_code == 422
        assert response.json()["error"]["code"] == "invalid_request"


def test_every_response_is_no_store(client) -> None:
    health = client.get("/healthz")
    not_found = client.get("/not-found")
    joined = client.post("/v1/sessions", json=join_body("headers"))

    for response in (health, not_found, joined):
        assert response.headers["cache-control"] == "no-store"
        assert response.headers["pragma"] == "no-cache"


def test_openapi_exposes_only_allowlisted_game_card_fields(client) -> None:
    schema = client.get("/openapi.json").json()
    card_schema = schema["components"]["schemas"]["PublicPetCardV1"]
    properties = set(card_schema["properties"])

    assert properties == {
        "schema_version",
        "pet_name",
        "character_id",
        "outfit_id",
        "background_id",
        "social_state",
    }
    join_properties = set(schema["components"]["schemas"]["JoinSessionRequest"]["properties"])
    assert join_properties == {
        "participant_id",
        "join_request_id",
        "discovery_token",
        "public_card",
    }
    encounter_credential = set(schema["components"]["schemas"]["EncounterCredential"]["properties"])
    assert encounter_credential == {
        "participant_id",
        "nonce",
        "encounter_id",
        "encounter_nonce",
    }
    cancel_request = set(schema["components"]["schemas"]["CancelRequest"]["properties"])
    assert cancel_request == encounter_credential
    peer_card_response = schema["components"]["schemas"]["PeerCardResponse"]
    assert set(peer_card_response["properties"]) == {
        "encounter_id",
        "encounter_nonce",
        "public_card",
    }
    assert set(peer_card_response["required"]) == {
        "encounter_id",
        "encounter_nonce",
        "public_card",
    }
