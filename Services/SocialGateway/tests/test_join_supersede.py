import asyncio
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy

from conftest import credential, join_body, token

from social_gateway.models import JoinSessionRequest, SessionStatus


def test_new_ni_session_atomically_supersedes_lost_waiting_join(
    client,
    clock,
    store,
) -> None:
    participant_id = "install_bearer_128_bits_minimum_opaque_123"
    old_body = join_body("lost-response", participant_id=participant_id)
    old_join = client.post("/v1/sessions", json=old_body).json()
    replacement_body = join_body("new-ni-session", participant_id=participant_id)

    replacement = client.post("/v1/sessions", json=replacement_body)
    old_status = client.post(
        f"/v1/sessions/{old_join['session_id']}/status",
        json=credential(old_join, participant_id),
    )
    delayed_old_replay = client.post("/v1/sessions", json=old_body)

    assert replacement.status_code == 201
    assert replacement.json()["status"] == "waiting"
    assert replacement.json()["session_id"] != old_join["session_id"]
    assert replacement.json()["nonce"] != old_join["nonce"]
    assert old_status.json()["status"] == "cancelled"
    assert delayed_old_replay.status_code == 201
    assert delayed_old_replay.json()["session_id"] == old_join["session_id"]
    assert delayed_old_replay.json()["nonce"] == old_join["nonce"]
    assert delayed_old_replay.json()["status"] == "cancelled"
    assert store._sessions[old_join["session_id"]].discovery_token is None
    assert store._sessions[old_join["session_id"]].public_card is None
    assert store._active_by_participant[participant_id] == replacement.json()["session_id"]

    conflicting_old_body = deepcopy(old_body)
    conflicting_old_body["discovery_token"] = token("changed-old-payload")
    conflict = client.post("/v1/sessions", json=conflicting_old_body)
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "idempotency_conflict"
    assert store._active_by_participant[participant_id] == replacement.json()["session_id"]

    clock.advance(6)
    assert (
        client.post(
            f"/v1/sessions/{old_join['session_id']}/status",
            json=credential(old_join, participant_id),
        ).status_code
        == 404
    )
    replay_after_session_tombstone_purge = client.post(
        "/v1/sessions",
        json=old_body,
    )
    assert replay_after_session_tombstone_purge.status_code == 201
    assert replay_after_session_tombstone_purge.json()["session_id"] == old_join["session_id"]
    assert replay_after_session_tombstone_purge.json()["status"] == "cancelled"
    assert store._active_by_participant[participant_id] == replacement.json()["session_id"]


def test_superseding_matched_session_cancels_peer_and_old_encounter(
    client,
    store,
) -> None:
    first_body = join_body("matched-first")
    second_body = join_body("matched-second")
    first = client.post("/v1/sessions", json=first_body).json()
    second = client.post("/v1/sessions", json=second_body).json()
    old_encounter_id = second["encounter_id"]
    assert old_encounter_id is not None

    replacement_body = join_body(
        "matched-first-new-ni-session",
        participant_id=first_body["participant_id"],
    )
    replacement = client.post("/v1/sessions", json=replacement_body).json()

    first_cancelled = client.post(
        f"/v1/sessions/{first['session_id']}/status",
        json=credential(first, first_body["participant_id"]),
    ).json()
    second_cancelled = client.post(
        f"/v1/sessions/{second['session_id']}/status",
        json=credential(second, second_body["participant_id"]),
    ).json()
    assert replacement["status"] == "waiting"
    assert first_cancelled["status"] == "cancelled"
    assert second_cancelled["status"] == "cancelled"
    assert first_cancelled["peer_discovery_token"] is None
    assert second_cancelled["peer_discovery_token"] is None
    assert store._encounters[old_encounter_id].status == SessionStatus.CANCELLED
    assert store._encounters[old_encounter_id].purge_at is not None
    for session_id in (first["session_id"], second["session_id"]):
        assert store._sessions[session_id].discovery_token is None
        assert store._sessions[session_id].public_card is None

    third_body = join_body("replacement-peer")
    third = client.post("/v1/sessions", json=third_body).json()
    replacement_state_before_replay = client.post(
        f"/v1/sessions/{replacement['session_id']}/status",
        json=credential(replacement, replacement_body["participant_id"]),
    ).json()
    assert third["status"] == "matched"
    assert replacement_state_before_replay["status"] == "matched"

    delayed_first = client.post("/v1/sessions", json=first_body).json()
    delayed_second = client.post("/v1/sessions", json=second_body).json()
    replacement_state_after_replay = client.post(
        f"/v1/sessions/{replacement['session_id']}/status",
        json=credential(replacement, replacement_body["participant_id"]),
    ).json()

    assert delayed_first["session_id"] == first["session_id"]
    assert delayed_first["status"] == "cancelled"
    assert delayed_second["session_id"] == second["session_id"]
    assert delayed_second["status"] == "cancelled"
    assert (
        replacement_state_after_replay["encounter_id"]
        == replacement_state_before_replay["encounter_id"]
    )
    assert store._active_by_participant[first_body["participant_id"]] == replacement["session_id"]


def test_concurrent_new_attempts_leave_exactly_one_active_session(store) -> None:
    participant_id = "concurrent_install_bearer_opaque_128_bits_123"
    bodies = [
        join_body(
            f"same-participant-{index}",
            participant_id=participant_id,
            join_request_id=f"join_request_concurrent_replace_{index:02d}_opaque",
        )
        for index in range(16)
    ]
    requests = [JoinSessionRequest.model_validate(body) for body in bodies]

    def join_one(request):
        return asyncio.run(store.join(request))

    with ThreadPoolExecutor(max_workers=8) as executor:
        responses = list(executor.map(join_one, requests))

    assert len({response.session_id for response in responses}) == len(responses)
    active_session_id = store._active_by_participant[participant_id]
    assert store._sessions[active_session_id].status == SessionStatus.WAITING
    assert sum(session.status == SessionStatus.WAITING for session in store._sessions.values()) == 1
    assert (
        sum(session.status == SessionStatus.CANCELLED for session in store._sessions.values())
        == len(responses) - 1
    )

    original_session_by_request = {
        request.join_request_id: response.session_id
        for request, response in zip(requests, responses)
    }
    replays = [asyncio.run(store.join(request)) for request in requests]
    for request, replay in zip(requests, replays):
        assert replay.session_id == original_session_by_request[request.join_request_id]
        if replay.session_id == active_session_id:
            assert replay.status == SessionStatus.WAITING
        else:
            assert replay.status == SessionStatus.CANCELLED
            assert store._sessions[replay.session_id].discovery_token is None
            assert store._sessions[replay.session_id].public_card is None
    assert store._active_by_participant[participant_id] == active_session_id
