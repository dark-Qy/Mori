"""Metadata-only operational audit events.

Health context, generated narration, prompts, headers, credentials, and raw
exceptions are intentionally absent from this interface, so callers cannot
accidentally pass them to the standard logger.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass
from typing import Optional, Protocol


@dataclass(frozen=True)
class SafeAuditEvent:
    request_id: str
    outcome: str
    upstream_status: Optional[int] = None


class AuditSink(Protocol):
    def record(self, event: SafeAuditEvent) -> None: ...


class StructuredAuditSink:
    def __init__(self, logger: Optional[logging.Logger] = None) -> None:
        self._logger = logger or logging.getLogger("narration_gateway.audit")

    def record(self, event: SafeAuditEvent) -> None:
        self._logger.info("narration_result %s", json.dumps(asdict(event), separators=(",", ":")))


class NullAuditSink:
    def record(self, event: SafeAuditEvent) -> None:
        del event
