from datetime import timedelta

import pytest
from conftest import credential, encounter_credential, join_body


def prepare_confirmable_pair(client):
    bodies = {
        "source": join_body("transfer-source"),
        "destination": join_body("transfer-destination"),
    }
    joined = {
        "source": client.post("/v1/sessions", json=bodies["source"]).json(),
        "destination": client.post("/v1/sessions", json=bodies["destination"]).json(),
    }
    states = {}
    encounter_auth = {}
    for role in ("source", "destination"):
        states[role] = client.post(
            f"/v1/sessions/{joined[role]['session_id']}/status",
            json=credential(joined[role], bodies[role]["participant_id"]),
        ).json()
        encounter_auth[role] = encounter_credential(
            states[role],
            joined[role],
            bodies[role]["participant_id"],
        )

    assert states["source"]["transfer_role"] == "source"
    assert states["destination"]["transfer_role"] == "destination"

    for role in ("source", "destination"):
        response = client.post(
            f"/v1/sessions/{joined[role]['session_id']}/proximity-ready",
            json=encounter_auth[role],
        )
        assert response.status_code == 200
    for role in ("source", "destination"):
        response = client.post(
            f"/v1/sessions/{joined[role]['session_id']}/peer-card",
            json=encounter_auth[role],
        )
        assert response.status_code == 200

    return bodies, joined, encounter_auth


@pytest.mark.parametrize("first_confirmer", ["source", "destination"])
def test_confirmed_pair_receives_one_synchronized_transfer_animation(
    client,
    clock,
    config,
    first_confirmer,
) -> None:
    bodies, joined, encounter_auth = prepare_confirmable_pair(client)
    second_confirmer = "destination" if first_confirmer == "source" else "source"

    first_response = client.post(
        f"/v1/sessions/{joined[first_confirmer]['session_id']}/confirm",
        json=encounter_auth[first_confirmer],
    )
    assert first_response.status_code == 200
    assert first_response.json()["transfer_animation"] is None

    confirmed_at = clock.value
    second_response = client.post(
        f"/v1/sessions/{joined[second_confirmer]['session_id']}/confirm",
        json=encounter_auth[second_confirmer],
    )
    assert second_response.status_code == 200
    assert second_response.json()["status"] == "confirmed"

    snapshots = {}
    for role in ("source", "destination"):
        snapshots[role] = client.post(
            f"/v1/sessions/{joined[role]['session_id']}/status",
            json=credential(joined[role], bodies[role]["participant_id"]),
        ).json()

    source_cue = snapshots["source"]["transfer_animation"]
    destination_cue = snapshots["destination"]["transfer_animation"]
    assert source_cue is not None
    assert destination_cue is not None
    assert source_cue["schema_version"] == "pet_transfer_animation_v1"
    assert source_cue["role"] == "source"
    assert destination_cue["role"] == "destination"
    assert source_cue["event_id"] == destination_cue["event_id"]
    assert source_cue["event_id"] == snapshots["source"]["encounter_id"]
    assert source_cue["starts_at"] == destination_cue["starts_at"]
    assert source_cue["duration_ms"] == destination_cue["duration_ms"] == 900
    expected_start = confirmed_at + timedelta(seconds=config.transfer_animation_lead_seconds)
    assert source_cue["starts_at"] == expected_start.isoformat().replace("+00:00", "Z")

    clock.advance(2)
    retry = client.post(
        f"/v1/sessions/{joined['source']['session_id']}/confirm",
        json=encounter_auth["source"],
    )
    late_status = client.post(
        f"/v1/sessions/{joined['destination']['session_id']}/status",
        json=credential(
            joined["destination"],
            bodies["destination"]["participant_id"],
        ),
    )
    assert retry.status_code == 200
    assert late_status.status_code == 200
    assert retry.json()["transfer_animation"] == source_cue
    assert late_status.json()["transfer_animation"] == destination_cue


def test_animation_cue_is_absent_before_bilateral_confirmation(client) -> None:
    bodies, joined, encounter_auth = prepare_confirmable_pair(client)

    for role in ("source", "destination"):
        state = client.post(
            f"/v1/sessions/{joined[role]['session_id']}/status",
            json=credential(joined[role], bodies[role]["participant_id"]),
        )
        assert state.json()["transfer_animation"] is None

    client.post(
        f"/v1/sessions/{joined['source']['session_id']}/confirm",
        json=encounter_auth["source"],
    )
    waiting = client.post(
        f"/v1/sessions/{joined['source']['session_id']}/status",
        json=credential(joined["source"], bodies["source"]["participant_id"]),
    )
    assert waiting.json()["transfer_animation"] is None
