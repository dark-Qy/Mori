"""ASGI boundary controls that do not inspect or log request contents."""

from __future__ import annotations

import hmac
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Dict, List, Optional, Tuple

from starlette.responses import JSONResponse

ASGIApp = Callable[
    [Dict[str, Any], Callable[..., Awaitable[Dict[str, Any]]], Callable[..., Awaitable[None]]],
    Awaitable[None],
]


class RequestBoundaryMiddleware:
    def __init__(
        self,
        app: ASGIApp,
        max_request_bytes: int,
        access_token: Optional[str],
        rate_limit_requests: int,
        rate_limit_window_seconds: int,
    ) -> None:
        self._app = app
        self._max_request_bytes = max_request_bytes
        self._access_token = access_token
        self._limiter = InMemoryRateLimiter(
            limit=rate_limit_requests,
            window_seconds=rate_limit_window_seconds,
        )

    async def __call__(
        self, scope: Dict[str, Any], receive: Callable[..., Any], send: Callable[..., Any]
    ) -> None:
        protected_paths = {
            "/v1/narrations",
            "/v1/weekly-memories/polish",
            "/v1/chat/reply",
        }
        if scope.get("type") != "http" or scope.get("path") not in protected_paths:
            await self._app(scope, receive, send)
            return

        async def no_store_send(message: Dict[str, Any]) -> None:
            if message.get("type") == "http.response.start":
                headers = list(message.get("headers", []))
                headers.append((b"cache-control", b"no-store"))
                message = {**message, "headers": headers}
            await send(message)

        if scope.get("method") != "POST":
            await self._app(scope, receive, no_store_send)
            return

        headers = {key.lower(): value for key, value in scope.get("headers", [])}
        if self._access_token is None:
            await self._send_error(
                scope,
                receive,
                no_store_send,
                status_code=503,
                code="service_unavailable",
                message="Narration access is not configured.",
            )
            return

        authorization = headers.get(b"authorization", b"").decode("latin-1")
        scheme, separator, supplied_token = authorization.partition(" ")
        if (
            not separator
            or scheme.lower() != "bearer"
            or not hmac.compare_digest(supplied_token, self._access_token)
        ):
            await self._send_error(
                scope,
                receive,
                no_store_send,
                status_code=401,
                code="unauthorized",
                message="A valid gateway bearer token is required.",
                extra_headers=[(b"www-authenticate", b"Bearer")],
            )
            return

        allowed, retry_after = self._limiter.allow()
        if not allowed:
            await self._send_error(
                scope,
                receive,
                no_store_send,
                status_code=429,
                code="rate_limited",
                message="Narration request limit exceeded.",
                extra_headers=[(b"retry-after", str(retry_after).encode("ascii"))],
            )
            return

        content_type = (
            headers.get(b"content-type", b"").decode("latin-1").split(";", 1)[0].strip().lower()
        )
        if content_type != "application/json":
            response = JSONResponse(
                status_code=415,
                content={
                    "error": {
                        "code": "unsupported_media_type",
                        "message": "Content-Type must be application/json.",
                    }
                },
            )
            await response(scope, receive, no_store_send)
            return

        content_length = headers.get(b"content-length")
        if content_length is not None:
            try:
                if int(content_length) > self._max_request_bytes:
                    await self._send_too_large(scope, receive, no_store_send)
                    return
            except ValueError:
                pass

        received_bytes = 0
        buffered_messages: List[Dict[str, Any]] = []
        while True:
            message = await receive()
            if message.get("type") == "http.request":
                received_bytes += len(message.get("body", b""))
                if received_bytes > self._max_request_bytes:
                    await self._send_too_large(scope, receive, no_store_send)
                    return
            buffered_messages.append(message)
            if message.get("type") != "http.request" or not message.get("more_body", False):
                break

        message_index = 0

        async def replay_receive() -> Dict[str, Any]:
            nonlocal message_index
            if message_index >= len(buffered_messages):
                return {"type": "http.disconnect"}
            message = buffered_messages[message_index]
            message_index += 1
            return message

        await self._app(scope, replay_receive, no_store_send)

    @staticmethod
    async def _send_too_large(
        scope: Dict[str, Any], receive: Callable[..., Any], send: Callable[..., Any]
    ) -> None:
        response = JSONResponse(
            status_code=413,
            content={
                "error": {
                    "code": "request_too_large",
                    "message": "Request body exceeds the configured limit.",
                }
            },
        )
        await response(scope, receive, send)

    @staticmethod
    async def _send_error(
        scope: Dict[str, Any],
        receive: Callable[..., Any],
        send: Callable[..., Any],
        *,
        status_code: int,
        code: str,
        message: str,
        extra_headers: Optional[List[Tuple[bytes, bytes]]] = None,
    ) -> None:
        response = JSONResponse(
            status_code=status_code,
            content={"error": {"code": code, "message": message}},
            headers={
                key.decode("ascii"): value.decode("ascii") for key, value in (extra_headers or [])
            },
        )
        await response(scope, receive, send)


@dataclass
class InMemoryRateLimiter:
    """A conservative per-process fixed-window guard for the single trusted token."""

    limit: int
    window_seconds: int
    _timestamps: deque[float] = field(default_factory=deque)
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def allow(self, now: Optional[float] = None) -> Tuple[bool, int]:
        timestamp = time.monotonic() if now is None else now
        cutoff = timestamp - self.window_seconds
        with self._lock:
            while self._timestamps and self._timestamps[0] <= cutoff:
                self._timestamps.popleft()
            if len(self._timestamps) >= self.limit:
                retry_after = max(1, int(self.window_seconds - (timestamp - self._timestamps[0])))
                return False, retry_after
            self._timestamps.append(timestamp)
            return True, 0
