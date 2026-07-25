"""Short-lived, one-time binding from validated chat replies to speech."""

from __future__ import annotations

import threading
import time
from collections import OrderedDict
from typing import Callable, Optional


def _without_inline_acting_directions(reply: str) -> str:
    """Remove balanced, nested, or malformed parenthetical directions."""

    output: list[str] = []
    depth = 0
    for character in reply:
        if character in "(（":
            depth += 1
            continue
        if character in ")）":
            if depth > 0:
                depth -= 1
            continue
        if depth == 0:
            output.append(character)
    return "".join(output).strip()


class SpeechGrantStore:
    """Keeps provider-approved copy in memory until one speech request consumes it."""

    def __init__(
        self,
        *,
        ttl_seconds: float = 60.0,
        max_entries: int = 512,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._ttl_seconds = ttl_seconds
        self._max_entries = max_entries
        self._clock = clock
        self._entries: OrderedDict[str, tuple[float, str]] = OrderedDict()
        self._lock = threading.Lock()

    def issue(self, request_id: str, reply: str) -> None:
        safe_reply = _without_inline_acting_directions(reply)
        if not safe_reply:
            return
        now = self._clock()
        with self._lock:
            self._discard_expired(now)
            self._entries[request_id] = (now + self._ttl_seconds, safe_reply)
            self._entries.move_to_end(request_id)
            while len(self._entries) > self._max_entries:
                self._entries.popitem(last=False)

    def consume(self, request_id: str) -> Optional[str]:
        now = self._clock()
        with self._lock:
            self._discard_expired(now)
            entry = self._entries.pop(request_id, None)
        return None if entry is None else entry[1]

    def _discard_expired(self, now: float) -> None:
        expired = [
            request_id for request_id, (expires_at, _) in self._entries.items() if expires_at <= now
        ]
        for request_id in expired:
            self._entries.pop(request_id, None)
