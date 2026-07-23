"""Concurrency-safe in-memory rendezvous state machine."""

from __future__ import annotations

import hashlib
import json
import secrets
import threading
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Callable, Deque, Dict, Optional, Tuple

from .config import GatewayConfig
from .models import (
    CleanupResponse,
    JoinSessionRequest,
    PeerCardResponse,
    PublicPetCardV1,
    SessionJoinedResponse,
    SessionStateResponse,
    SessionStatus,
)


class StoreError(Exception):
    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__()
        self.status_code = status_code
        self.code = code
        self.message = message


@dataclass
class SessionRecord:
    session_id: str
    participant_id: str
    join_request_id: str
    nonce: str
    discovery_token: Optional[str]
    public_card: Optional[PublicPetCardV1]
    status: SessionStatus
    expires_at: datetime
    deadline_at: datetime
    encounter_id: Optional[str] = None
    encounter_nonce: Optional[str] = None
    last_peer_participant_id: Optional[str] = None
    avoid_peer_until: Optional[datetime] = None
    proximity_ready_at: Optional[datetime] = None
    preview_released: bool = False
    confirmed: bool = False
    purge_at: Optional[datetime] = None


@dataclass
class EncounterRecord:
    encounter_id: str
    nonce: str
    first_session_id: str
    second_session_id: str
    status: SessionStatus
    expires_at: datetime
    candidate_expires_at: datetime
    proximity_verified_at: Optional[datetime] = None
    purge_at: Optional[datetime] = None


@dataclass
class IdempotencyRecord:
    request_fingerprint: str
    session_id: str
    response: Optional[SessionJoinedResponse] = None


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class RendezvousStore:
    def __init__(
        self,
        config: GatewayConfig,
        *,
        clock: Callable[[], datetime] = utc_now,
    ) -> None:
        self._config = config
        self._clock = clock
        self._lock = threading.RLock()
        self._sessions: Dict[str, SessionRecord] = {}
        self._encounters: Dict[str, EncounterRecord] = {}
        self._active_by_participant: Dict[str, str] = {}
        self._waiting: Deque[str] = deque()
        self._idempotency: Dict[Tuple[str, str], IdempotencyRecord] = {}

    async def join(self, request: JoinSessionRequest) -> SessionJoinedResponse:
        with self._lock:
            now = self._now()
            self._cleanup_locked(now)
            idempotency_key = (request.participant_id, request.join_request_id)
            request_fingerprint = self._request_fingerprint(request)
            previous = self._idempotency.get(idempotency_key)
            if previous is not None:
                if not secrets.compare_digest(previous.request_fingerprint, request_fingerprint):
                    raise StoreError(
                        409,
                        "idempotency_conflict",
                        "This join_request_id was already used with a different payload.",
                    )
                if previous.response is not None:
                    return previous.response.model_copy(deep=True)
                previous_session = self._sessions.get(previous.session_id)
                if previous_session is not None:
                    return self._joined_snapshot(previous_session)
                del self._idempotency[idempotency_key]
            active_session_id = self._active_by_participant.get(request.participant_id)
            if active_session_id is not None:
                active_session = self._sessions.get(active_session_id)
                if active_session is not None:
                    if active_session.status == SessionStatus.CONFIRMED:
                        raise StoreError(
                            409,
                            "confirmed_session_not_supersedable",
                            "A confirmed session cannot be superseded.",
                        )
                    self._cancel_session_and_encounter_locked(
                        active_session,
                        now,
                    )
                else:
                    del self._active_by_participant[request.participant_id]
            if len(self._active_by_participant) >= self._config.max_active_participants:
                raise StoreError(503, "capacity_reached", "Rendezvous capacity is full.")

            deadline_at = now + timedelta(seconds=self._config.encounter_ttl_seconds)
            session = SessionRecord(
                session_id=self._new_id(),
                participant_id=request.participant_id,
                join_request_id=request.join_request_id,
                nonce=secrets.token_urlsafe(32),
                discovery_token=request.discovery_token,
                public_card=request.public_card.model_copy(deep=True),
                status=SessionStatus.WAITING,
                expires_at=min(
                    deadline_at,
                    now + timedelta(seconds=self._config.waiting_ttl_seconds),
                ),
                deadline_at=deadline_at,
            )
            self._sessions[session.session_id] = session
            self._active_by_participant[session.participant_id] = session.session_id
            self._idempotency[idempotency_key] = IdempotencyRecord(
                request_fingerprint=request_fingerprint,
                session_id=session.session_id,
            )

            self._waiting.append(session.session_id)
            self._fill_candidates_locked(now)
            response = self._joined_snapshot(session)
            self._idempotency[idempotency_key].response = response.model_copy(deep=True)
            return response

    async def status(
        self, session_id: str, participant_id: str, nonce: str
    ) -> SessionStateResponse:
        with self._lock:
            self._cleanup_locked(self._now())
            session = self._authorize(session_id, participant_id, nonce)
            return self._snapshot(session)

    async def mark_proximity_ready(
        self,
        session_id: str,
        participant_id: str,
        nonce: str,
        encounter_id: str,
        encounter_nonce: str,
    ) -> SessionStateResponse:
        with self._lock:
            self._cleanup_locked(self._now())
            session = self._authorize(session_id, participant_id, nonce)
            encounter, peer = self._active_encounter(
                session,
                encounter_id,
                encounter_nonce,
            )
            if encounter.proximity_verified_at is not None:
                return self._snapshot(session)

            now = self._now()
            session.proximity_ready_at = now
            if peer.proximity_ready_at is not None:
                delta = abs((now - peer.proximity_ready_at).total_seconds())
                if delta <= self._config.proximity_window_seconds:
                    encounter.proximity_verified_at = now
                else:
                    peer.proximity_ready_at = None
            if encounter.proximity_verified_at is not None:
                encounter.status = SessionStatus.PROXIMITY_READY
                session.status = SessionStatus.PROXIMITY_READY
                peer.status = SessionStatus.PROXIMITY_READY
            return self._snapshot(session)

    async def peer_card(
        self,
        session_id: str,
        participant_id: str,
        nonce: str,
        encounter_id: str,
        encounter_nonce: str,
    ) -> PeerCardResponse:
        with self._lock:
            self._cleanup_locked(self._now())
            session = self._authorize(session_id, participant_id, nonce)
            encounter, peer = self._active_encounter(
                session,
                encounter_id,
                encounter_nonce,
                allow_confirmed=True,
            )
            if encounter.proximity_verified_at is None:
                raise StoreError(
                    409,
                    "proximity_not_ready",
                    "Both participants must report proximity within the verification window.",
                )
            if peer.public_card is None:
                raise StoreError(410, "card_unavailable", "The peer card is no longer available.")
            session.preview_released = True
            return PeerCardResponse(
                encounter_id=encounter.encounter_id,
                encounter_nonce=encounter.nonce,
                public_card=peer.public_card.model_copy(deep=True),
            )

    async def confirm(
        self,
        session_id: str,
        participant_id: str,
        nonce: str,
        encounter_id: str,
        encounter_nonce: str,
    ) -> SessionStateResponse:
        with self._lock:
            self._cleanup_locked(self._now())
            session = self._authorize(session_id, participant_id, nonce)
            encounter, peer = self._active_encounter(
                session,
                encounter_id,
                encounter_nonce,
                allow_confirmed=True,
            )
            if encounter.proximity_verified_at is None:
                raise StoreError(
                    409,
                    "proximity_not_ready",
                    "Proximity has not been verified.",
                )
            if not session.preview_released:
                raise StoreError(
                    409,
                    "preview_required",
                    "This participant must retrieve the peer card before confirmation.",
                )
            session.confirmed = True
            if peer.confirmed:
                encounter.status = SessionStatus.CONFIRMED
                session.status = SessionStatus.CONFIRMED
                peer.status = SessionStatus.CONFIRMED
                encounter.purge_at = encounter.expires_at
                session.purge_at = encounter.expires_at
                peer.purge_at = encounter.expires_at
                self._deactivate(session)
                self._deactivate(peer)
                self._refresh_idempotency_response(session)
                self._refresh_idempotency_response(peer)
            return self._snapshot(session)

    async def cancel(
        self,
        session_id: str,
        participant_id: str,
        nonce: str,
        encounter_id: Optional[str],
        encounter_nonce: Optional[str],
    ) -> SessionStateResponse:
        with self._lock:
            now = self._now()
            self._cleanup_locked(now)
            session = self._authorize(session_id, participant_id, nonce)
            if session.status == SessionStatus.CANCELLED:
                self._validate_cancel_generation(
                    session,
                    encounter_id,
                    encounter_nonce,
                )
                return self._snapshot(session)
            if session.status == SessionStatus.EXPIRED:
                raise StoreError(410, "session_expired", "The session has expired.")
            if session.encounter_id is None:
                if encounter_id is not None or encounter_nonce is not None:
                    raise StoreError(
                        409,
                        "stale_encounter",
                        "The supplied encounter generation is no longer current.",
                    )
            else:
                if encounter_id is None or encounter_nonce is None:
                    raise StoreError(
                        409,
                        "encounter_generation_required",
                        "Cancelling a candidate requires its current encounter generation.",
                    )
                self._validate_encounter_generation(
                    session,
                    encounter_id,
                    encounter_nonce,
                )
            if session.status == SessionStatus.CONFIRMED:
                raise StoreError(
                    409,
                    "encounter_already_confirmed",
                    "A confirmed encounter cannot be cancelled.",
                )
            self._cancel_session_and_encounter_locked(session, now)
            return self._snapshot(session)

    async def cleanup(self) -> CleanupResponse:
        with self._lock:
            return self._cleanup_locked(self._now())

    def _pair_locked(self, first: SessionRecord, second: SessionRecord, now: datetime) -> None:
        if first.participant_id == second.participant_id:
            raise RuntimeError("A participant cannot be paired with itself.")
        encounter_id = self._new_id()
        encounter_nonce = secrets.token_urlsafe(24)
        expires_at = min(first.deadline_at, second.deadline_at)
        encounter = EncounterRecord(
            encounter_id=encounter_id,
            nonce=encounter_nonce,
            first_session_id=first.session_id,
            second_session_id=second.session_id,
            status=SessionStatus.MATCHED,
            expires_at=expires_at,
            candidate_expires_at=min(
                expires_at,
                now + timedelta(seconds=self._config.candidate_ttl_seconds),
            ),
        )
        self._encounters[encounter_id] = encounter
        for session in (first, second):
            session.status = SessionStatus.MATCHED
            session.encounter_id = encounter_id
            session.encounter_nonce = encounter_nonce
            session.expires_at = expires_at

    def _fill_candidates_locked(self, now: datetime) -> None:
        waiting = deque(
            session_id
            for session_id in self._waiting
            if (
                session_id in self._sessions
                and self._sessions[session_id].status == SessionStatus.WAITING
            )
        )
        unmatched: Deque[str] = deque()
        while waiting:
            first_id = waiting.popleft()
            first = self._sessions[first_id]
            deferred: Deque[str] = deque()
            peer: Optional[SessionRecord] = None
            while waiting:
                candidate_id = waiting.popleft()
                candidate = self._sessions[candidate_id]
                if self._can_pair(first, candidate, now):
                    peer = candidate
                    break
                deferred.append(candidate_id)
            waiting.extendleft(reversed(deferred))
            if peer is None:
                unmatched.append(first_id)
            else:
                self._pair_locked(first, peer, now)
        self._waiting = unmatched

    @staticmethod
    def _can_pair(
        first: SessionRecord,
        second: SessionRecord,
        now: datetime,
    ) -> bool:
        first_still_avoids_second = (
            first.last_peer_participant_id == second.participant_id
            and first.avoid_peer_until is not None
            and first.avoid_peer_until > now
        )
        second_still_avoids_first = (
            second.last_peer_participant_id == first.participant_id
            and second.avoid_peer_until is not None
            and second.avoid_peer_until > now
        )
        return (
            first.participant_id != second.participant_id
            and not first_still_avoids_second
            and not second_still_avoids_first
        )

    def _active_encounter(
        self,
        session: SessionRecord,
        encounter_id: str,
        encounter_nonce: str,
        *,
        allow_confirmed: bool = False,
    ) -> Tuple[EncounterRecord, SessionRecord]:
        if session.status == SessionStatus.EXPIRED:
            raise StoreError(410, "session_expired", "The session has expired.")
        if session.status == SessionStatus.CANCELLED:
            raise StoreError(409, "encounter_cancelled", "The encounter was cancelled.")
        encounter = self._validate_encounter_generation(
            session,
            encounter_id,
            encounter_nonce,
        )
        if session.status == SessionStatus.WAITING or session.encounter_id is None:
            raise StoreError(409, "not_matched", "The session has not been matched.")
        if session.status == SessionStatus.CONFIRMED and not allow_confirmed:
            raise StoreError(409, "encounter_already_confirmed", "The encounter is complete.")
        peer_id = (
            encounter.second_session_id
            if encounter.first_session_id == session.session_id
            else encounter.first_session_id
        )
        peer = self._sessions[peer_id]
        return encounter, peer

    def _validate_encounter_generation(
        self,
        session: SessionRecord,
        encounter_id: str,
        encounter_nonce: str,
    ) -> EncounterRecord:
        if (
            session.encounter_id is None
            or session.encounter_nonce is None
            or not secrets.compare_digest(session.encounter_id, encounter_id)
            or not secrets.compare_digest(session.encounter_nonce, encounter_nonce)
        ):
            raise StoreError(
                409,
                "stale_encounter",
                "The supplied encounter generation is no longer current.",
            )
        encounter = self._encounters.get(session.encounter_id)
        if encounter is None or not secrets.compare_digest(
            encounter.nonce,
            encounter_nonce,
        ):
            raise StoreError(
                409,
                "stale_encounter",
                "The supplied encounter generation is no longer current.",
            )
        return encounter

    def _validate_cancel_generation(
        self,
        session: SessionRecord,
        encounter_id: Optional[str],
        encounter_nonce: Optional[str],
    ) -> None:
        if session.encounter_id is None:
            if encounter_id is not None or encounter_nonce is not None:
                raise StoreError(
                    409,
                    "stale_encounter",
                    "The supplied encounter generation is no longer current.",
                )
            return
        if encounter_id is None or encounter_nonce is None:
            raise StoreError(
                409,
                "encounter_generation_required",
                "Cancelling a candidate requires its current encounter generation.",
            )
        self._validate_encounter_generation(
            session,
            encounter_id,
            encounter_nonce,
        )

    def _authorize(self, session_id: str, participant_id: str, nonce: str) -> SessionRecord:
        session = self._sessions.get(session_id)
        if (
            session is None
            or not secrets.compare_digest(session.participant_id, participant_id)
            or not secrets.compare_digest(session.nonce, nonce)
        ):
            raise StoreError(404, "session_not_found", "Session was not found.")
        return session

    def _snapshot(self, session: SessionRecord) -> SessionStateResponse:
        peer = self._peer_for(session)
        encounter = (
            self._encounters.get(session.encounter_id) if session.encounter_id is not None else None
        )
        return SessionStateResponse(
            session_id=session.session_id,
            status=session.status,
            expires_at=session.expires_at,
            encounter_id=session.encounter_id,
            encounter_nonce=session.encounter_nonce,
            peer_discovery_token=(
                peer.discovery_token
                if peer is not None
                and session.status not in {SessionStatus.CANCELLED, SessionStatus.EXPIRED}
                else None
            ),
            self_proximity_ready=session.proximity_ready_at is not None,
            peer_proximity_ready=(
                peer.proximity_ready_at is not None if peer is not None else False
            ),
            proximity_verified=(
                encounter.proximity_verified_at is not None if encounter is not None else False
            ),
            proximity_verified_at=(
                encounter.proximity_verified_at if encounter is not None else None
            ),
            self_preview_released=session.preview_released,
            peer_preview_released=peer.preview_released if peer is not None else False,
            self_confirmed=session.confirmed,
            peer_confirmed=peer.confirmed if peer is not None else False,
        )

    def _joined_snapshot(self, session: SessionRecord) -> SessionJoinedResponse:
        state = self._snapshot(session)
        return SessionJoinedResponse(**state.model_dump(), nonce=session.nonce)

    def _peer_for(self, session: SessionRecord) -> Optional[SessionRecord]:
        if session.encounter_id is None:
            return None
        encounter = self._encounters.get(session.encounter_id)
        if encounter is None:
            return None
        peer_id = (
            encounter.second_session_id
            if encounter.first_session_id == session.session_id
            else encounter.first_session_id
        )
        return self._sessions.get(peer_id)

    def _cancel_session_locked(self, session: SessionRecord, now: datetime) -> None:
        session.status = SessionStatus.CANCELLED
        session.discovery_token = None
        session.public_card = None
        session.purge_at = now + timedelta(seconds=self._config.tombstone_ttl_seconds)
        self._deactivate(session)
        self._refresh_idempotency_response(session)

    def _cancel_session_and_encounter_locked(
        self,
        session: SessionRecord,
        now: datetime,
    ) -> None:
        if session.encounter_id is None:
            self._cancel_session_locked(session, now)
            return
        encounter = self._encounters.get(session.encounter_id)
        if encounter is None:
            self._cancel_session_locked(session, now)
            return
        encounter.status = SessionStatus.CANCELLED
        encounter.purge_at = now + timedelta(seconds=self._config.tombstone_ttl_seconds)
        for session_id in (
            encounter.first_session_id,
            encounter.second_session_id,
        ):
            encounter_session = self._sessions.get(session_id)
            if encounter_session is not None:
                self._cancel_session_locked(encounter_session, now)

    def _expire_session_locked(self, session: SessionRecord, now: datetime) -> None:
        session.status = SessionStatus.EXPIRED
        session.discovery_token = None
        session.public_card = None
        session.purge_at = now + timedelta(seconds=self._config.tombstone_ttl_seconds)
        self._deactivate(session)
        self._refresh_idempotency_response(session)

    def _deactivate(self, session: SessionRecord) -> None:
        if self._active_by_participant.get(session.participant_id) == session.session_id:
            del self._active_by_participant[session.participant_id]

    def _refresh_idempotency_response(self, session: SessionRecord) -> None:
        record = self._idempotency.get((session.participant_id, session.join_request_id))
        if record is not None:
            response = self._joined_snapshot(session)
            if session.status in {
                SessionStatus.CONFIRMED,
                SessionStatus.CANCELLED,
                SessionStatus.EXPIRED,
            }:
                response.peer_discovery_token = None
            record.response = response

    def _release_candidate_locked(
        self,
        encounter: EncounterRecord,
        now: datetime,
    ) -> int:
        first = self._sessions.get(encounter.first_session_id)
        second = self._sessions.get(encounter.second_session_id)
        if first is not None and second is not None:
            first.last_peer_participant_id = second.participant_id
            second.last_peer_participant_id = first.participant_id
            avoid_until = now + timedelta(seconds=self._config.candidate_ttl_seconds)
            first.avoid_peer_until = avoid_until
            second.avoid_peer_until = avoid_until

        expired_sessions = 0
        for session in (first, second):
            if session is None:
                continue
            session.status = SessionStatus.WAITING
            session.encounter_id = None
            session.encounter_nonce = None
            session.proximity_ready_at = None
            session.preview_released = False
            session.confirmed = False
            if session.deadline_at <= now:
                self._expire_session_locked(session, now)
                expired_sessions += 1
            else:
                session.expires_at = min(
                    session.deadline_at,
                    now + timedelta(seconds=self._config.waiting_ttl_seconds),
                )
                self._waiting.append(session.session_id)
                self._refresh_idempotency_response(session)
        return expired_sessions

    def _cleanup_locked(self, now: datetime) -> CleanupResponse:
        expired_sessions = 0
        expired_encounters = 0
        purged_sessions = 0
        purged_encounters = 0

        for encounter_id, encounter in list(self._encounters.items()):
            if encounter.status == SessionStatus.MATCHED and (
                encounter.candidate_expires_at <= now or encounter.expires_at <= now
            ):
                del self._encounters[encounter_id]
                expired_sessions += self._release_candidate_locked(encounter, now)
                expired_encounters += 1
                purged_encounters += 1
                continue
            if (
                encounter.status
                not in {
                    SessionStatus.CANCELLED,
                    SessionStatus.EXPIRED,
                    SessionStatus.CONFIRMED,
                }
                and encounter.expires_at <= now
            ):
                encounter.status = SessionStatus.EXPIRED
                encounter.purge_at = now + timedelta(seconds=self._config.tombstone_ttl_seconds)
                for session_id in (
                    encounter.first_session_id,
                    encounter.second_session_id,
                ):
                    session = self._sessions.get(session_id)
                    if session is not None:
                        self._expire_session_locked(session, now)
                        expired_sessions += 1
                expired_encounters += 1

        for session in list(self._sessions.values()):
            if session.status == SessionStatus.WAITING and session.expires_at <= now:
                self._expire_session_locked(session, now)
                expired_sessions += 1

        for session_id, session in list(self._sessions.items()):
            if session.purge_at is not None and session.purge_at <= now:
                del self._sessions[session_id]
                # Keep the sanitized idempotency response for the process
                # lifetime. Forgetting a superseded join_request_id here would
                # let a sufficiently delayed retry become a fresh join and
                # cancel the participant's replacement session.
                purged_sessions += 1

        for encounter_id, encounter in list(self._encounters.items()):
            purge_at = encounter.purge_at
            if (
                encounter.status == SessionStatus.CONFIRMED
                and encounter.expires_at <= now
                and purge_at is None
            ):
                encounter.purge_at = now
                purge_at = now
            if purge_at is not None and purge_at <= now:
                del self._encounters[encounter_id]
                purged_encounters += 1

        self._waiting = deque(
            session_id
            for session_id in self._waiting
            if (
                session_id in self._sessions
                and self._sessions[session_id].status == SessionStatus.WAITING
            )
        )
        self._fill_candidates_locked(now)

        return CleanupResponse(
            expired_sessions=expired_sessions,
            expired_encounters=expired_encounters,
            purged_sessions=purged_sessions,
            purged_encounters=purged_encounters,
        )

    def _now(self) -> datetime:
        now = self._clock()
        if now.tzinfo is None:
            raise RuntimeError("RendezvousStore clock must return a timezone-aware datetime.")
        return now

    def _new_id(self) -> str:
        while True:
            candidate = secrets.token_hex(16)
            if candidate not in self._sessions and candidate not in self._encounters:
                return candidate

    @staticmethod
    def _request_fingerprint(request: JoinSessionRequest) -> str:
        canonical_payload = json.dumps(
            request.model_dump(mode="json"),
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        return hashlib.sha256(canonical_payload).hexdigest()
