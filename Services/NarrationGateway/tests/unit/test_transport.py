import json
import time

import anyio
import httpx
import pytest

from narration_gateway.transport import (
    HttpxChatCompletionTransport,
    UpstreamNetworkError,
    UpstreamResponseTooLarge,
    UpstreamTimeout,
)

pytestmark = pytest.mark.anyio


async def test_http_transport_targets_chat_completions_and_sets_bearer_header() -> None:
    observed = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        observed["path"] = request.url.path
        observed["authorization"] = request.headers["authorization"]
        observed["payload"] = json.loads(request.content)
        return httpx.Response(200, json={"choices": []})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    transport = HttpxChatCompletionTransport(
        "https://gateway.example/v1/chat/completions",
        "private-token",
        client=client,
    )

    response = await transport.complete(
        {"model": "test", "messages": []}, timeout_seconds=1.0, max_response_bytes=1_024
    )

    assert response.status_code == 200
    assert observed == {
        "path": "/v1/chat/completions",
        "authorization": "Bearer private-token",
        "payload": {"model": "test", "messages": []},
    }
    await client.aclose()


async def test_http_transport_rejects_large_content_length_before_buffering() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        del request
        return httpx.Response(200, headers={"content-length": "9000"}, content=b"small")

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    transport = HttpxChatCompletionTransport(
        "https://gateway.example/v1/chat/completions",
        "private-token",
        client=client,
    )

    with pytest.raises(UpstreamResponseTooLarge):
        await transport.complete({}, timeout_seconds=1.0, max_response_bytes=1_024)
    await client.aclose()


async def test_http_transport_normalizes_timeout_without_exposing_request() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("provider timeout", request=request)

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    transport = HttpxChatCompletionTransport(
        "https://gateway.example/v1/chat/completions",
        "private-token",
        client=client,
    )

    with pytest.raises(UpstreamTimeout) as captured:
        await transport.complete({}, timeout_seconds=1.0, max_response_bytes=1_024)

    assert str(captured.value) == ""
    await client.aclose()


class DripStream(httpx.AsyncByteStream):
    async def __aiter__(self):
        for _ in range(20):
            await anyio.sleep(0.05)
            yield b"x"


async def test_hard_deadline_stops_a_slow_drip_response() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        del request
        return httpx.Response(200, stream=DripStream())

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    transport = HttpxChatCompletionTransport(
        "https://gateway.example/v1/chat/completions",
        "private-token",
        client=client,
    )
    started = time.monotonic()

    with pytest.raises(UpstreamTimeout):
        await transport.complete({}, timeout_seconds=0.25, max_response_bytes=1_024)

    assert time.monotonic() - started < 0.75
    await client.aclose()


async def test_http_transport_normalizes_network_error_without_exposing_request() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("private network detail", request=request)

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    transport = HttpxChatCompletionTransport(
        "https://gateway.example/v1/chat/completions",
        "private-token",
        client=client,
    )

    with pytest.raises(UpstreamNetworkError) as captured:
        await transport.complete({}, timeout_seconds=1.0, max_response_bytes=1_024)

    assert str(captured.value) == ""
    await client.aclose()
