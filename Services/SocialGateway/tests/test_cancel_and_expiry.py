from conftest import credential, encounter_credential, join_body


def test_waiting_cancel_is_idempotent_and_releases_participant(client) -> None:
    body = join_body("solo")
    joined = client.post("/v1/sessions", json=body).json()
    auth = credential(joined, body["participant_id"])

    cancelled = client.post(f"/v1/sessions/{joined['session_id']}/cancel", json=auth)
    retry = client.post(f"/v1/sessions/{joined['session_id']}/cancel", json=auth)
    replacement_body = join_body(
        "solo-replacement",
        participant_id=body["participant_id"],
    )
    replacement = client.post("/v1/sessions", json=replacement_body)

    assert cancelled.status_code == 200
    assert cancelled.json()["status"] == "cancelled"
    assert cancelled.json()["peer_discovery_token"] is None
    assert retry.json() == cancelled.json()
    assert replacement.status_code == 201


def test_cancel_propagates_to_peer_and_removes_sensitive_exchange_data(client) -> None:
    first_body = join_body("first")
    second_body = join_body("second")
    first = client.post("/v1/sessions", json=first_body).json()
    second = client.post("/v1/sessions", json=second_body).json()
    first_auth = credential(first, first_body["participant_id"])
    second_auth = credential(second, second_body["participant_id"])
    first_state = client.post(
        f"/v1/sessions/{first['session_id']}/status",
        json=first_auth,
    ).json()
    first_encounter = encounter_credential(
        first_state,
        first,
        first_body["participant_id"],
    )
    second_encounter = encounter_credential(
        second,
        second,
        second_body["participant_id"],
    )

    missing_generation = client.post(
        f"/v1/sessions/{first['session_id']}/cancel",
        json=first_auth,
    )
    assert missing_generation.status_code == 409
    assert missing_generation.json()["error"]["code"] == "encounter_generation_required"

    cancelled = client.post(
        f"/v1/sessions/{first['session_id']}/cancel",
        json=first_encounter,
    )
    peer_status = client.post(f"/v1/sessions/{second['session_id']}/status", json=second_auth)
    peer_ready = client.post(
        f"/v1/sessions/{second['session_id']}/proximity-ready",
        json=second_encounter,
    )

    assert cancelled.json()["status"] == "cancelled"
    assert peer_status.json()["status"] == "cancelled"
    assert peer_status.json()["peer_discovery_token"] is None
    assert peer_ready.status_code == 409
    assert peer_ready.json()["error"]["code"] == "encounter_cancelled"


def test_waiting_session_expires_then_tombstone_is_purged(client, clock) -> None:
    body = join_body("expiring")
    joined = client.post("/v1/sessions", json=body).json()
    auth = credential(joined, body["participant_id"])

    clock.advance(16)
    expired = client.post(f"/v1/sessions/{joined['session_id']}/status", json=auth)

    assert expired.status_code == 200
    assert expired.json()["status"] == "expired"
    assert expired.json()["peer_discovery_token"] is None

    clock.advance(6)
    purged = client.post(f"/v1/sessions/{joined['session_id']}/status", json=auth)
    assert purged.status_code == 404


def test_matched_encounter_expires_both_sessions(client, clock) -> None:
    first_body = join_body("alpha")
    second_body = join_body("bravo")
    first = client.post("/v1/sessions", json=first_body).json()
    second = client.post("/v1/sessions", json=second_body).json()
    first_auth = credential(first, first_body["participant_id"])
    second_auth = credential(second, second_body["participant_id"])

    clock.advance(31)
    first_expired = client.post(f"/v1/sessions/{first['session_id']}/status", json=first_auth)
    second_expired = client.post(f"/v1/sessions/{second['session_id']}/status", json=second_auth)

    assert first_expired.json()["status"] == "expired"
    assert second_expired.json()["status"] == "expired"
    assert first_expired.json()["peer_discovery_token"] is None
    assert second_expired.json()["peer_discovery_token"] is None


def test_cleanup_endpoint_reports_expiration_without_accepting_client_data(client, clock) -> None:
    client.post("/v1/sessions", json=join_body("cleanup"))
    clock.advance(16)

    response = client.post("/v1/maintenance/cleanup", json={})

    assert response.status_code == 200
    assert response.json() == {
        "expired_sessions": 1,
        "expired_encounters": 0,
        "purged_sessions": 0,
        "purged_encounters": 0,
    }


def test_confirmed_records_are_pruned_at_encounter_expiry(client, clock) -> None:
    first_body = join_body("confirmed-a")
    second_body = join_body("confirmed-b")
    first = client.post("/v1/sessions", json=first_body).json()
    second = client.post("/v1/sessions", json=second_body).json()
    first_auth = credential(first, first_body["participant_id"])
    first_state = client.post(
        f"/v1/sessions/{first['session_id']}/status",
        json=first_auth,
    ).json()
    first_encounter = encounter_credential(
        first_state,
        first,
        first_body["participant_id"],
    )
    second_encounter = encounter_credential(
        second,
        second,
        second_body["participant_id"],
    )
    for joined, auth in ((first, first_encounter), (second, second_encounter)):
        client.post(
            f"/v1/sessions/{joined['session_id']}/proximity-ready",
            json=auth,
        )
    for joined, auth in ((first, first_encounter), (second, second_encounter)):
        client.post(
            f"/v1/sessions/{joined['session_id']}/peer-card",
            json=auth,
        )
    client.post(f"/v1/sessions/{first['session_id']}/confirm", json=first_encounter)
    client.post(f"/v1/sessions/{second['session_id']}/confirm", json=second_encounter)

    clock.advance(31)
    gone = client.post(
        f"/v1/sessions/{first['session_id']}/status",
        json=first_auth,
    )

    assert gone.status_code == 404


def test_expired_session_rejects_state_changes(client, clock) -> None:
    body = join_body("expired-action")
    joined = client.post("/v1/sessions", json=body).json()
    auth = credential(joined, body["participant_id"])
    clock.advance(16)

    response = client.post(
        f"/v1/sessions/{joined['session_id']}/cancel",
        json=auth,
    )

    assert response.status_code == 410
    assert response.json()["error"]["code"] == "session_expired"
