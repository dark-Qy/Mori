"""Metadata-only audit events.

The interface intentionally has no participant ID, NI token, nonce, or pet-card
field, so normal application logging cannot accidentally record rendezvous data.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass
from typing import Optional, Protocol


@dataclass(frozen=True)
class SafeAuditEvent:
    action: str
    outcome: str
    session_id: Optional[str] = None
    encounter_id: Optional[str] = None


class AuditSink(Protocol):
    def record(self, event: SafeAuditEvent) -> None: ...


class StructuredAuditSink:
    def __init__(self, logger: Optional[logging.Logger] = None) -> None:
        self._logger = logger or logging.getLogger("social_gateway.audit")

    def record(self, event: SafeAuditEvent) -> None:
        self._logger.info(
            "social_rendezvous %s",
            json.dumps(asdict(event), separators=(",", ":")),
        )


class NullAuditSink:
    def record(self, event: SafeAuditEvent) -> None:
        del event
