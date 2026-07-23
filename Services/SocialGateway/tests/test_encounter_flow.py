from copy import deepcopy

from conftest import card, credential, encounter_credential, join_body, token


def join_pair(client):
    first_body = join_body("alpha")
    second_body = join_body("bravo")
    first = client.post("/v1/sessions", json=first_body)
    second = client.post("/v1/sessions", json=second_body)
    assert first.status_code == 201
    assert second.status_code == 201
    return first_body, first.json(), second_body, second.json()


def current_encounter_auth(client, body, joined):
    state = client.post(
        f"/v1/sessions/{joined['session_id']}/status",
        json=credential(joined, body["participant_id"]),
    )
    assert state.status_code == 200
    return encounter_credential(state.json(), joined, body["participant_id"])


def test_complete_two_party_encounter_and_idempotent_confirmation(client) -> None:
    first_body, first, second_body, second = join_pair(client)

    assert first["status"] == "waiting"
    assert first["encounter_id"] is None
    assert first["peer_discovery_token"] is None
    assert second["status"] == "matched"
    assert second["peer_discovery_token"] == token("alpha")
    assert second["encounter_id"]
    assert second["encounter_nonce"]

    first_credential = credential(first, first_body["participant_id"])
    first_status = client.post(f"/v1/sessions/{first['session_id']}/status", json=first_credential)
    assert first_status.status_code == 200
    assert first_status.json()["status"] == "matched"
    assert first_status.json()["encounter_id"] == second["encounter_id"]
    assert first_status.json()["encounter_nonce"] == second["encounter_nonce"]
    assert first_status.json()["peer_discovery_token"] == token("bravo")
    first_encounter = encounter_credential(
        first_status.json(),
        first,
        first_body["participant_id"],
    )
    second_encounter = encounter_credential(
        second,
        second,
        second_body["participant_id"],
    )

    blocked = client.post(
        f"/v1/sessions/{first['session_id']}/peer-card",
        json=first_encounter,
    )
    assert blocked.status_code == 409
    assert blocked.json()["error"]["code"] == "proximity_not_ready"

    first_ready = client.post(
        f"/v1/sessions/{first['session_id']}/proximity-ready",
        json=first_encounter,
    )
    assert first_ready.status_code == 200
    assert first_ready.json()["status"] == "matched"
    assert first_ready.json()["self_proximity_ready"] is True
    assert first_ready.json()["peer_proximity_ready"] is False

    second_ready = client.post(
        f"/v1/sessions/{second['session_id']}/proximity-ready",
        json=second_encounter,
    )
    assert second_ready.status_code == 200
    assert second_ready.json()["status"] == "proximity_ready"
    assert second_ready.json()["self_proximity_ready"] is True
    assert second_ready.json()["peer_proximity_ready"] is True
    assert second_ready.json()["proximity_verified"] is True
    assert second_ready.json()["proximity_verified_at"] is not None
    second_ready_retry = client.post(
        f"/v1/sessions/{second['session_id']}/proximity-ready",
        json=second_encounter,
    )
    assert second_ready_retry.json() == second_ready.json()

    first_card = client.post(
        f"/v1/sessions/{first['session_id']}/peer-card",
        json=first_encounter,
    )
    second_card = client.post(
        f"/v1/sessions/{second['session_id']}/peer-card",
        json=second_encounter,
    )
    assert first_card.status_code == 200
    assert first_card.json()["encounter_id"] == first_encounter["encounter_id"]
    assert first_card.json()["encounter_nonce"] == first_encounter["encounter_nonce"]
    assert first_card.json()["public_card"] == card("bravo")
    assert second_card.json()["encounter_id"] == second_encounter["encounter_id"]
    assert second_card.json()["encounter_nonce"] == second_encounter["encounter_nonce"]
    assert second_card.json()["public_card"] == card("alpha")
    preview_status = client.post(
        f"/v1/sessions/{first['session_id']}/status",
        json=first_credential,
    ).json()
    assert preview_status["self_preview_released"] is True
    assert preview_status["peer_preview_released"] is True

    first_confirm = client.post(
        f"/v1/sessions/{first['session_id']}/confirm",
        json=first_encounter,
    )
    first_retry = client.post(
        f"/v1/sessions/{first['session_id']}/confirm",
        json=first_encounter,
    )
    assert first_confirm.status_code == 200
    assert first_confirm.json()["status"] == "proximity_ready"
    assert first_confirm.json()["self_confirmed"] is True
    assert first_confirm.json()["peer_confirmed"] is False
    assert first_retry.json() == first_confirm.json()

    second_confirm = client.post(
        f"/v1/sessions/{second['session_id']}/confirm",
        json=second_encounter,
    )
    assert second_confirm.status_code == 200
    assert second_confirm.json()["status"] == "confirmed"
    assert second_confirm.json()["self_confirmed"] is True
    assert second_confirm.json()["peer_confirmed"] is True

    completed_for_first = client.post(
        f"/v1/sessions/{first['session_id']}/status", json=first_credential
    )
    assert completed_for_first.json()["status"] == "confirmed"
    assert completed_for_first.json()["self_confirmed"] is True
    assert completed_for_first.json()["peer_confirmed"] is True

    retry_after_completion = client.post(
        f"/v1/sessions/{first['session_id']}/confirm",
        json=first_encounter,
    )
    assert retry_after_completion.status_code == 200
    assert retry_after_completion.json()["status"] == "confirmed"


def test_confirm_is_forbidden_until_both_report_proximity(client) -> None:
    first_body, first, _, _ = join_pair(client)

    response = client.post(
        f"/v1/sessions/{first['session_id']}/confirm",
        json=current_encounter_auth(client, first_body, first),
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "proximity_not_ready"


def test_new_attempt_supersedes_same_participant_without_self_pairing(client) -> None:
    shared_participant = "same_install_opaque_12345"
    first_body = join_body("one", participant_id=shared_participant)
    first = client.post("/v1/sessions", json=first_body)
    replacement = client.post(
        "/v1/sessions",
        json=join_body("copy", participant_id=shared_participant),
    )
    second_body = join_body("two")
    second = client.post("/v1/sessions", json=second_body)
    first_status = client.post(
        f"/v1/sessions/{first.json()['session_id']}/status",
        json=credential(first.json(), shared_participant),
    )

    assert first.status_code == 201
    assert first.json()["status"] == "waiting"
    assert replacement.status_code == 201
    assert replacement.json()["status"] == "waiting"
    assert replacement.json()["session_id"] != first.json()["session_id"]
    assert first_status.json()["status"] == "cancelled"
    assert second.status_code == 201
    assert second.json()["status"] == "matched"
    assert second.json()["peer_discovery_token"] == token("copy")


def test_join_request_id_is_idempotent_and_payload_bound(client) -> None:
    body = join_body("idempotent")

    first = client.post("/v1/sessions", json=body)
    replay = client.post("/v1/sessions", json=body)
    client.post("/v1/sessions", json=join_body("idempotent-peer"))
    replay_after_pairing = client.post("/v1/sessions", json=body)
    conflicting_body = deepcopy(body)
    conflicting_body["discovery_token"] = token("different-payload")
    conflict = client.post("/v1/sessions", json=conflicting_body)

    assert first.status_code == 201
    assert replay.status_code == 201
    assert replay.json() == first.json()
    assert replay_after_pairing.json() == first.json()
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "idempotency_conflict"


def test_four_participants_form_two_distinct_pairs(client) -> None:
    responses = [
        client.post("/v1/sessions", json=join_body(label)).json()
        for label in ("one", "two", "three", "four")
    ]

    assert responses[0]["status"] == "waiting"
    assert responses[1]["status"] == "matched"
    assert responses[2]["status"] == "waiting"
    assert responses[3]["status"] == "matched"
    assert responses[1]["encounter_id"] != responses[3]["encounter_id"]


def test_credentials_are_bound_to_both_session_and_participant(client) -> None:
    first_body, first, second_body, second = join_pair(client)

    wrong_participant = {
        "participant_id": second_body["participant_id"],
        "nonce": first["nonce"],
    }
    wrong_nonce = {
        "participant_id": first_body["participant_id"],
        "nonce": second["nonce"],
    }

    for bad_credential in (wrong_participant, wrong_nonce):
        response = client.post(
            f"/v1/sessions/{first['session_id']}/status",
            json=bad_credential,
        )
        assert response.status_code == 404
        assert response.json()["error"]["code"] == "session_not_found"


def test_completed_participant_can_join_a_new_encounter(client) -> None:
    first_body, first, second_body, second = join_pair(client)
    first_encounter = current_encounter_auth(client, first_body, first)
    second_encounter = current_encounter_auth(client, second_body, second)
    for session, auth in ((first, first_encounter), (second, second_encounter)):
        assert (
            client.post(
                f"/v1/sessions/{session['session_id']}/proximity-ready", json=auth
            ).status_code
            == 200
        )
    for session, auth in ((first, first_encounter), (second, second_encounter)):
        assert (
            client.post(
                f"/v1/sessions/{session['session_id']}/peer-card",
                json=auth,
            ).status_code
            == 200
        )
    client.post(f"/v1/sessions/{first['session_id']}/confirm", json=first_encounter)
    client.post(f"/v1/sessions/{second['session_id']}/confirm", json=second_encounter)

    new_body = join_body(
        "alpha-new",
        participant_id=first_body["participant_id"],
    )
    new_join = client.post("/v1/sessions", json=new_body)
    completed_after_new_join = client.post(
        f"/v1/sessions/{first['session_id']}/status",
        json=credential(first, first_body["participant_id"]),
    )
    completed_join_replay = client.post("/v1/sessions", json=first_body)

    assert new_join.status_code == 201
    assert new_join.json()["status"] == "waiting"
    assert completed_after_new_join.status_code == 200
    assert completed_after_new_join.json()["status"] == "confirmed"
    assert completed_join_replay.json()["session_id"] == first["session_id"]
    assert completed_join_replay.json()["status"] == "confirmed"
    assert completed_join_replay.json()["peer_discovery_token"] is None


def test_confirmed_encounter_cannot_be_cancelled(client) -> None:
    first_body, first, second_body, second = join_pair(client)
    first_encounter = current_encounter_auth(client, first_body, first)
    second_encounter = current_encounter_auth(client, second_body, second)
    for session, auth in ((first, first_encounter), (second, second_encounter)):
        client.post(
            f"/v1/sessions/{session['session_id']}/proximity-ready",
            json=auth,
        )
    for session, auth in ((first, first_encounter), (second, second_encounter)):
        client.post(
            f"/v1/sessions/{session['session_id']}/peer-card",
            json=auth,
        )
    client.post(f"/v1/sessions/{first['session_id']}/confirm", json=first_encounter)
    client.post(f"/v1/sessions/{second['session_id']}/confirm", json=second_encounter)

    response = client.post(
        f"/v1/sessions/{first['session_id']}/cancel",
        json=first_encounter,
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "encounter_already_confirmed"


def test_proximity_reports_must_overlap_and_preview_precedes_confirm(client, clock) -> None:
    first_body, first, second_body, second = join_pair(client)
    first_encounter = current_encounter_auth(client, first_body, first)
    second_encounter = current_encounter_auth(client, second_body, second)

    first_ready = client.post(
        f"/v1/sessions/{first['session_id']}/proximity-ready",
        json=first_encounter,
    )
    assert first_ready.json()["self_proximity_ready"] is True
    assert first_ready.json()["proximity_verified"] is False

    clock.advance(6)
    late_second = client.post(
        f"/v1/sessions/{second['session_id']}/proximity-ready",
        json=second_encounter,
    )
    assert late_second.json()["status"] == "matched"
    assert late_second.json()["self_proximity_ready"] is True
    assert late_second.json()["peer_proximity_ready"] is False
    assert late_second.json()["proximity_verified"] is False
    blocked_card = client.post(
        f"/v1/sessions/{second['session_id']}/peer-card",
        json=second_encounter,
    )
    assert blocked_card.status_code == 409
    assert blocked_card.json()["error"]["code"] == "proximity_not_ready"

    verified = client.post(
        f"/v1/sessions/{first['session_id']}/proximity-ready",
        json=first_encounter,
    )
    assert verified.json()["status"] == "proximity_ready"
    assert verified.json()["proximity_verified"] is True
    locked_at = verified.json()["proximity_verified_at"]

    clock.advance(10)
    verified_retry = client.post(
        f"/v1/sessions/{second['session_id']}/proximity-ready",
        json=second_encounter,
    )
    assert verified_retry.json()["proximity_verified"] is True
    assert verified_retry.json()["proximity_verified_at"] == locked_at

    preview_required = client.post(
        f"/v1/sessions/{first['session_id']}/confirm",
        json=first_encounter,
    )
    assert preview_required.status_code == 409
    assert preview_required.json()["error"]["code"] == "preview_required"

    client.post(
        f"/v1/sessions/{first['session_id']}/peer-card",
        json=first_encounter,
    )
    first_confirm = client.post(
        f"/v1/sessions/{first['session_id']}/confirm",
        json=first_encounter,
    )
    assert first_confirm.status_code == 200
    assert first_confirm.json()["self_confirmed"] is True

    second_preview_required = client.post(
        f"/v1/sessions/{second['session_id']}/confirm",
        json=second_encounter,
    )
    assert second_preview_required.status_code == 409
    assert second_preview_required.json()["error"]["code"] == "preview_required"
    client.post(
        f"/v1/sessions/{second['session_id']}/peer-card",
        json=second_encounter,
    )
    completed = client.post(
        f"/v1/sessions/{second['session_id']}/confirm",
        json=second_encounter,
    )
    assert completed.json()["status"] == "confirmed"
