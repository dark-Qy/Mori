"""Environment-only configuration for the ephemeral rendezvous service."""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Mapping, Optional


def _bounded_int(
    environment: Mapping[str, str],
    name: str,
    default: int,
    minimum: int,
    maximum: int,
) -> int:
    raw = environment.get(name)
    value = default if raw is None else int(raw)
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def _bounded_float(
    environment: Mapping[str, str],
    name: str,
    default: float,
    minimum: float,
    maximum: float,
) -> float:
    raw = environment.get(name)
    value = default if raw is None else float(raw)
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


@dataclass(frozen=True)
class GatewayConfig:
    waiting_ttl_seconds: int = 60
    encounter_ttl_seconds: int = 180
    candidate_ttl_seconds: int = 12
    tombstone_ttl_seconds: int = 60
    proximity_window_seconds: float = 5.0
    transfer_animation_lead_seconds: float = 1.25
    transfer_animation_duration_ms: int = 900
    cleanup_interval_seconds: float = 1.0
    max_request_bytes: int = 16_384
    max_active_participants: int = 10_000

    @classmethod
    def from_environment(cls, environment: Optional[Mapping[str, str]] = None) -> "GatewayConfig":
        env = os.environ if environment is None else environment
        return cls(
            waiting_ttl_seconds=_bounded_int(env, "SOCIAL_WAITING_TTL_SECONDS", 60, 15, 300),
            encounter_ttl_seconds=_bounded_int(env, "SOCIAL_ENCOUNTER_TTL_SECONDS", 180, 30, 600),
            candidate_ttl_seconds=_bounded_int(env, "SOCIAL_CANDIDATE_TTL_SECONDS", 12, 5, 60),
            tombstone_ttl_seconds=_bounded_int(env, "SOCIAL_TOMBSTONE_TTL_SECONDS", 60, 5, 300),
            proximity_window_seconds=_bounded_float(
                env, "SOCIAL_PROXIMITY_WINDOW_SECONDS", 5.0, 1.0, 15.0
            ),
            transfer_animation_lead_seconds=_bounded_float(
                env, "SOCIAL_TRANSFER_ANIMATION_LEAD_SECONDS", 1.25, 0.75, 3.0
            ),
            transfer_animation_duration_ms=_bounded_int(
                env, "SOCIAL_TRANSFER_ANIMATION_DURATION_MS", 900, 500, 2_000
            ),
            cleanup_interval_seconds=_bounded_float(
                env, "SOCIAL_CLEANUP_INTERVAL_SECONDS", 1.0, 0.01, 60.0
            ),
            max_request_bytes=_bounded_int(env, "SOCIAL_MAX_REQUEST_BYTES", 16_384, 4_096, 65_536),
            max_active_participants=_bounded_int(
                env, "SOCIAL_MAX_ACTIVE_PARTICIPANTS", 10_000, 2, 100_000
            ),
        )
