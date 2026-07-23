import asyncio
from concurrent.futures import ThreadPoolExecutor

from conftest import card, credential, encounter_credential, join_body, token

from social_gateway.models import JoinSessionRequest


def test_timed_out_candidate_returns_to_waiting_then_can_retry(client, clock, store) -> None:
    first_body = join_body("retry-a")
    second_body = join_body("retry-b")
    first = client.post("/v1/sessions", json=first_body).json()
    second = client.post("/v1/sessions", json=second_body).json()
    first_auth = credential(first, first_body["participant_id"])
    second_auth = credential(second, second_body["participant_id"])
    old_encounter_id = second["encounter_id"]

    clock.advance(9)
    first_waiting = client.post(
        f"/v1/sessions/{first['session_id']}/status",
        json=first_auth,
    )
    second_waiting = client.post(
        f"/v1/sessions/{second['session_id']}/status",
        json=second_auth,
    )

    for response in (first_waiting, second_waiting):
        assert response.json()["status"] == "waiting"
        assert response.json()["encounter_id"] is None
        assert response.json()["encounter_nonce"] is None
        assert response.json()["peer_discovery_token"] is None
        assert response.json()["proximity_verified"] is False
    assert store._sessions[first["session_id"]].nonce == first["nonce"]
    assert store._sessions[first["session_id"]].discovery_token == token("retry-a")
    assert store._sessions[second["session_id"]].nonce == second["nonce"]
    assert store._sessions[second["session_id"]].discovery_token == token("retry-b")

    clock.advance(9)
    first_rematched = client.post(
        f"/v1/sessions/{first['session_id']}/status",
        json=first_auth,
    )
    second_rematched = client.post(
        f"/v1/sessions/{second['session_id']}/status",
        json=second_auth,
    )

    assert first_rematched.json()["status"] == "matched"
    assert second_rematched.json()["status"] == "matched"
    assert first_rematched.json()["encounter_id"] != old_encounter_id
    assert first_rematched.json()["peer_discovery_token"] == token("retry-b")
    assert second_rematched.json()["peer_discovery_token"] == token("retry-a")


def test_multiple_timed_out_candidates_rotate_without_card_leak(client, clock) -> None:
    bodies = [join_body(label) for label in ("alpha", "bravo", "charlie", "delta")]
    joined = [client.post("/v1/sessions", json=body).json() for body in bodies]
    old_states = [
        client.post(
            f"/v1/sessions/{entry['session_id']}/status",
            json=credential(entry, body["participant_id"]),
        ).json()
        for body, entry in zip(bodies, joined)
    ]
    old_credentials = [
        encounter_credential(state, entry, body["participant_id"])
        for body, entry, state in zip(bodies, joined, old_states)
    ]
    old_encounters = {entry["encounter_id"] for entry in joined if entry["encounter_id"]}
    assert len(old_encounters) == 2

    clock.advance(9)
    statuses = [
        client.post(
            f"/v1/sessions/{entry['session_id']}/status",
            json=credential(entry, body["participant_id"]),
        ).json()
        for body, entry in zip(bodies, joined)
    ]

    assert all(status["status"] == "matched" for status in statuses)
    new_encounters = {status["encounter_id"] for status in statuses}
    assert len(new_encounters) == 2
    assert new_encounters.isdisjoint(old_encounters)
    assert statuses[0]["peer_discovery_token"] == token("charlie")
    assert statuses[1]["peer_discovery_token"] == token("delta")
    assert statuses[2]["peer_discovery_token"] == token("alpha")
    assert statuses[3]["peer_discovery_token"] == token("bravo")

    first_new_credential = encounter_credential(
        statuses[0],
        joined[0],
        bodies[0]["participant_id"],
    )
    third_new_credential = encounter_credential(
        statuses[2],
        joined[2],
        bodies[2]["participant_id"],
    )
    for endpoint in ("proximity-ready", "peer-card", "confirm", "cancel"):
        delayed = client.post(
            f"/v1/sessions/{joined[0]['session_id']}/{endpoint}",
            json=old_credentials[0],
        )
        assert delayed.status_code == 409
        assert delayed.json()["error"]["code"] == "stale_encounter"
    unchanged = client.post(
        f"/v1/sessions/{joined[0]['session_id']}/status",
        json=credential(joined[0], bodies[0]["participant_id"]),
    ).json()
    assert unchanged["encounter_id"] == statuses[0]["encounter_id"]
    assert unchanged["self_proximity_ready"] is False
    assert unchanged["self_preview_released"] is False
    assert unchanged["self_confirmed"] is False

    blocked = client.post(
        f"/v1/sessions/{joined[0]['session_id']}/peer-card",
        json=first_new_credential,
    )
    assert blocked.status_code == 409
    assert blocked.json()["error"]["code"] == "proximity_not_ready"

    client.post(
        f"/v1/sessions/{joined[0]['session_id']}/proximity-ready",
        json=first_new_credential,
    )
    client.post(
        f"/v1/sessions/{joined[2]['session_id']}/proximity-ready",
        json=third_new_credential,
    )
    new_peer_card = client.post(
        f"/v1/sessions/{joined[0]['session_id']}/peer-card",
        json=first_new_credential,
    )
    assert new_peer_card.status_code == 200
    assert new_peer_card.json()["encounter_id"] == first_new_credential["encounter_id"]
    assert new_peer_card.json()["encounter_nonce"] == first_new_credential["encounter_nonce"]
    assert new_peer_card.json()["public_card"] == card("charlie")

    replay_of_old_matched_join = client.post("/v1/sessions", json=bodies[1]).json()
    assert replay_of_old_matched_join["nonce"] == joined[1]["nonce"]
    assert replay_of_old_matched_join["status"] == "waiting"
    assert replay_of_old_matched_join["peer_discovery_token"] is None


def test_concurrent_joins_create_unique_two_party_candidates(store) -> None:
    requests = [
        JoinSessionRequest.model_validate(join_body(f"concurrent-{index}")) for index in range(20)
    ]

    def join_one(request):
        return asyncio.run(store.join(request))

    with ThreadPoolExecutor(max_workers=10) as executor:
        responses = list(executor.map(join_one, requests))

    assert len({response.session_id for response in responses}) == 20
    assert len({response.nonce for response in responses}) == 20
    assert len(store._encounters) == 10
    assert not store._waiting
    for encounter in store._encounters.values():
        first = store._sessions[encounter.first_session_id]
        second = store._sessions[encounter.second_session_id]
        assert first.participant_id != second.participant_id
