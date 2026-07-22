"""Bounded OpenAI-compatible HTTP transport."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Optional, Protocol

import anyio
import httpx


class UpstreamTimeout(Exception):
    """The upstream did not complete within the configured deadline."""


class UpstreamResponseTooLarge(Exception):
    """The upstream body exceeded the configured byte budget."""


class UpstreamNetworkError(Exception):
    """The upstream could not be reached."""


@dataclass(frozen=True)
class UpstreamHTTPResponse:
    status_code: int
    body: bytes


class ChatCompletionTransport(Protocol):
    async def complete(
        self, payload: Dict[str, Any], *, timeout_seconds: float, max_response_bytes: int
    ) -> UpstreamHTTPResponse: ...


class HttpxChatCompletionTransport:
    """HTTP implementation that never reads an unbounded response body."""

    def __init__(self, url: str, api_key: str, client: Optional[httpx.AsyncClient] = None) -> None:
        self._url = url
        self._api_key = api_key
        self._client = client or httpx.AsyncClient(follow_redirects=False, trust_env=False)
        self._owns_client = client is None

    async def complete(
        self, payload: Dict[str, Any], *, timeout_seconds: float, max_response_bytes: int
    ) -> UpstreamHTTPResponse:
        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        try:
            with anyio.fail_after(timeout_seconds):
                async with self._client.stream(
                    "POST",
                    self._url,
                    headers=headers,
                    json=payload,
                    timeout=httpx.Timeout(timeout_seconds),
                ) as response:
                    content_length = response.headers.get("content-length")
                    if content_length is not None:
                        try:
                            if int(content_length) > max_response_bytes:
                                raise UpstreamResponseTooLarge
                        except ValueError:
                            pass

                    chunks = bytearray()
                    async for chunk in response.aiter_bytes():
                        chunks.extend(chunk)
                        if len(chunks) > max_response_bytes:
                            raise UpstreamResponseTooLarge
                    return UpstreamHTTPResponse(
                        status_code=response.status_code, body=bytes(chunks)
                    )
        except TimeoutError as error:
            raise UpstreamTimeout from error
        except httpx.TimeoutException as error:
            raise UpstreamTimeout from error
        except httpx.RequestError as error:
            raise UpstreamNetworkError from error

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()
