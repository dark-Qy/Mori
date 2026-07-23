"""Small ASGI request/response boundary for the public API."""

from __future__ import annotations

from typing import Any, Dict, List

from starlette.datastructures import Headers, MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send


class RequestBoundaryMiddleware:
    def __init__(self, app: ASGIApp, *, max_request_bytes: int) -> None:
        self.app = app
        self.max_request_bytes = max_request_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def no_store_send(message: Message) -> None:
            if message["type"] == "http.response.start":
                headers = MutableHeaders(scope=message)
                headers["Cache-Control"] = "no-store"
                headers["Pragma"] = "no-cache"
            await send(message)

        if scope["method"] not in {"POST", "PUT", "PATCH"}:
            await self.app(scope, receive, no_store_send)
            return

        headers = Headers(scope=scope)
        content_type = headers.get("content-type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            await self._error(no_store_send, 415, "unsupported_media_type")
            return

        content_length = headers.get("content-length")
        if content_length is not None:
            try:
                parsed_content_length = int(content_length)
                if parsed_content_length < 0:
                    await self._error(no_store_send, 400, "invalid_content_length")
                    return
                if parsed_content_length > self.max_request_bytes:
                    await self._error(no_store_send, 413, "request_too_large")
                    return
            except ValueError:
                await self._error(no_store_send, 400, "invalid_content_length")
                return

        body_parts: List[bytes] = []
        body_size = 0
        more_body = True
        while more_body:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            body = message.get("body", b"")
            body_size += len(body)
            if body_size > self.max_request_bytes:
                await self._error(no_store_send, 413, "request_too_large")
                return
            body_parts.append(body)
            more_body = bool(message.get("more_body", False))

        replayed = False

        async def replay_receive() -> Dict[str, Any]:
            nonlocal replayed
            if replayed:
                return {"type": "http.request", "body": b"", "more_body": False}
            replayed = True
            return {
                "type": "http.request",
                "body": b"".join(body_parts),
                "more_body": False,
            }

        await self.app(scope, replay_receive, no_store_send)

    @staticmethod
    async def _error(send: Send, status: int, code: str) -> None:
        body = (
            '{"error":{"code":"'
            + code
            + '","message":"Request rejected by the gateway boundary."}}'
        ).encode("utf-8")
        await send(
            {
                "type": "http.response.start",
                "status": status,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode("ascii")),
                ],
            }
        )
        await send({"type": "http.response.body", "body": body})
