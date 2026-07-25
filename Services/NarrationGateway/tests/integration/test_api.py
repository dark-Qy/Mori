from __future__ import annotations

import asyncio
from copy import deepcopy
from typing import Any, Dict

import httpx
import pytest
from conftest import openai_content_response, openai_response
from fastapi.testclient import TestClient

from narration_gateway.app import create_app
from narration_gateway.audit import NullAuditSink
from narration_gateway.config import GatewayConfig
from narration_gateway.speech_grants import SpeechGrantStore
from narration_gateway.transport import UpstreamHTTPResponse


class StaticTransport:
    def __init__(self, response: UpstreamHTTPResponse) -> None:
        self.response = response

    async def complete(
        self, payload: Dict[str, Any], *, timeout_seconds: float, max_response_bytes: int
    ) -> UpstreamHTTPResponse:
        del payload, timeout_seconds, max_response_bytes
        return self.response


class StaticSpeechTransport:
    def __init__(self, response: UpstreamHTTPResponse) -> None:
        self.response = response
        self.payload: Dict[str, Any] | None = None

    async def synthesize(
        self, payload: Dict[str, Any], *, timeout_seconds: float, max_response_bytes: int
    ) -> UpstreamHTTPResponse:
        del timeout_seconds, max_response_bytes
        self.payload = payload
        return self.response


class BlockingSpeechTransport:
    def __init__(self) -> None:
        self.started = asyncio.Event()
        self.release = asyncio.Event()

    async def synthesize(
        self, payload: Dict[str, Any], *, timeout_seconds: float, max_response_bytes: int
    ) -> UpstreamHTTPResponse:
        del payload, timeout_seconds, max_response_bytes
        self.started.set()
        await self.release.wait()
        return UpstreamHTTPResponse(
            status_code=200,
            body=b"ID3-bounded-mp3",
            content_type="audio/mpeg",
        )


def test_narration_endpoint_uses_injected_transport(
    configured_gateway, valid_request, authorization_headers
) -> None:
    app = create_app(
        config=configured_gateway,
        transport=StaticTransport(openai_response("warm")),
        audit_sink=NullAuditSink(),
    )

    response = TestClient(app).post(
        "/v1/narrations", json=valid_request, headers=authorization_headers
    )

    assert response.status_code == 200
    assert response.json() == {
        "request_id": "request-001",
        "narration": "我看见节奏有一点变化。先照顾此刻的自己，晚些我们再温柔地回顾。",
        "source": "upstream",
        "fallback_reason": None,
        "safe": True,
    }
    assert response.headers["cache-control"] == "no-store"


def test_missing_key_returns_local_fallback_without_network(
    valid_request, authorization_headers
) -> None:
    config = GatewayConfig.from_environment(
        {"NARRATION_GATEWAY_ACCESS_TOKEN": "test-gateway-access-token-12345"}
    )
    app = create_app(config=config, audit_sink=NullAuditSink())

    response = TestClient(app).post(
        "/v1/narrations", json=valid_request, headers=authorization_headers
    )

    assert response.status_code == 200
    assert response.json()["source"] == "fallback"
    assert response.json()["fallback_reason"] == "missing_configuration"


def test_extra_request_fields_get_sanitized_schema_error(
    configured_gateway, valid_request, authorization_headers
) -> None:
    body = deepcopy(valid_request)
    body["raw_prompt"] = "sensitive-health-text-must-not-be-reflected"
    app = create_app(
        config=configured_gateway,
        transport=StaticTransport(openai_response("calm")),
        audit_sink=NullAuditSink(),
    )

    response = TestClient(app).post("/v1/narrations", json=body, headers=authorization_headers)

    assert response.status_code == 422
    assert response.json() == {
        "error": {
            "code": "invalid_request",
            "message": "Request does not match the accepted schema.",
        }
    }
    assert "sensitive-health-text" not in response.text


def test_numeric_strings_are_not_coerced(
    configured_gateway, valid_request, authorization_headers
) -> None:
    body = deepcopy(valid_request)
    body["pet"]["level"] = "8"
    app = create_app(
        config=configured_gateway,
        transport=StaticTransport(openai_response("calm")),
        audit_sink=NullAuditSink(),
    )

    response = TestClient(app).post("/v1/narrations", json=body, headers=authorization_headers)

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_request"


def test_large_request_is_rejected_before_schema_parsing(
    configured_gateway, valid_request, authorization_headers
) -> None:
    tiny_config = GatewayConfig(
        upstream_base_url=configured_gateway.upstream_base_url,
        upstream_model=configured_gateway.upstream_model,
        upstream_api_key=configured_gateway.upstream_api_key,
        gateway_access_token=configured_gateway.gateway_access_token,
        max_request_bytes=200,
    )
    app = create_app(
        config=tiny_config,
        transport=StaticTransport(openai_response("calm")),
        audit_sink=NullAuditSink(),
    )

    response = TestClient(app).post(
        "/v1/narrations", json=valid_request, headers=authorization_headers
    )

    assert response.status_code == 413
    assert response.json()["error"]["code"] == "request_too_large"


def test_non_json_content_type_is_rejected(configured_gateway, authorization_headers) -> None:
    app = create_app(
        config=configured_gateway,
        transport=StaticTransport(openai_response("calm")),
        audit_sink=NullAuditSink(),
    )

    response = TestClient(app).post(
        "/v1/narrations",
        content="not-json",
        headers={**authorization_headers, "content-type": "text/plain"},
    )

    assert response.status_code == 415
    assert response.json()["error"]["code"] == "unsupported_media_type"


def test_health_endpoint_reports_configuration_without_secret(configured_gateway) -> None:
    app = create_app(
        config=configured_gateway,
        transport=StaticTransport(openai_response("calm")),
        audit_sink=NullAuditSink(),
    )

    response = TestClient(app).get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "upstream_configured": True}
    assert "test-secret-never-log" not in response.text


def test_missing_or_invalid_gateway_token_is_rejected_without_echo(
    configured_gateway, valid_request
) -> None:
    app = create_app(
        config=configured_gateway,
        transport=StaticTransport(openai_response("calm")),
        audit_sink=NullAuditSink(),
    )
    client = TestClient(app)

    missing = client.post("/v1/narrations", json=valid_request)
    invalid = client.post(
        "/v1/narrations",
        json=valid_request,
        headers={"Authorization": "Bearer wrong-private-token"},
    )

    assert missing.status_code == 401
    assert invalid.status_code == 401
    assert invalid.json()["error"]["code"] == "unauthorized"
    assert "wrong-private-token" not in invalid.text
    assert invalid.headers["cache-control"] == "no-store"


def test_unconfigured_gateway_auth_fails_closed(valid_request) -> None:
    config = GatewayConfig.from_environment({})
    app = create_app(config=config, audit_sink=NullAuditSink())

    response = TestClient(app).post("/v1/narrations", json=valid_request)

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "service_unavailable"


def test_rate_limit_is_enforced_before_upstream_use(valid_request) -> None:
    config = GatewayConfig(
        upstream_base_url="https://upstream.example",
        upstream_model="test-model",
        upstream_api_key="upstream-private-token",
        gateway_access_token="test-gateway-access-token-12345",
        rate_limit_requests=1,
        rate_limit_window_seconds=60,
    )
    app = create_app(
        config=config,
        transport=StaticTransport(openai_response("calm")),
        audit_sink=NullAuditSink(),
    )
    client = TestClient(app)
    headers = {"Authorization": "Bearer test-gateway-access-token-12345"}

    assert client.post("/v1/narrations", json=valid_request, headers=headers).status_code == 200
    limited = client.post("/v1/narrations", json=valid_request, headers=headers)

    assert limited.status_code == 429
    assert limited.json()["error"]["code"] == "rate_limited"
    assert int(limited.headers["retry-after"]) >= 1


def test_wrong_method_reaches_router_and_returns_405(configured_gateway) -> None:
    app = create_app(config=configured_gateway, audit_sink=NullAuditSink())

    response = TestClient(app).get("/v1/narrations")

    assert response.status_code == 405
    assert response.headers["cache-control"] == "no-store"


def test_weekly_polish_endpoint_returns_server_owned_copy_for_upstream_style(
    configured_gateway, valid_weekly_request, authorization_headers
) -> None:
    app = create_app(
        config=configured_gateway,
        transport=StaticTransport(
            openai_content_response(
                {
                    "style": "warm",
                    "focus": "movement",
                    "ending": "together",
                }
            )
        ),
        audit_sink=NullAuditSink(),
    )

    response = TestClient(app).post(
        "/v1/weekly-memories/polish",
        json=valid_weekly_request,
        headers=authorization_headers,
    )

    assert response.status_code == 200
    assert response.json() == {
        "request_id": "weekly-request-001",
        "source_hash": "weekly.source:abc12345",
        "title": "和网球一起向前",
        "body": (
            "这周我们一起留下了网球 45 分钟、游泳 60 分钟、42350 步、活跃 210 分钟、"
            "平均睡眠 435 分钟。下一段路，我们也一起走。"
        ),
        "source": "upstream",
        "fallback_reason": None,
        "safe": True,
    }
    assert response.headers["cache-control"] == "no-store"


def test_weekly_polish_endpoint_is_authenticated_and_strict(
    configured_gateway, valid_weekly_request, authorization_headers
) -> None:
    app = create_app(
        config=configured_gateway,
        transport=StaticTransport(
            openai_content_response({"style": "calm", "focus": "balanced", "ending": "trail"})
        ),
        audit_sink=NullAuditSink(),
    )
    client = TestClient(app)

    unauthorized = client.post("/v1/weekly-memories/polish", json=valid_weekly_request)
    unknown = deepcopy(valid_weekly_request)
    unknown["prompt"] = "invent a medical conclusion"
    invalid = client.post(
        "/v1/weekly-memories/polish",
        json=unknown,
        headers=authorization_headers,
    )

    assert unauthorized.status_code == 401
    assert unauthorized.headers["cache-control"] == "no-store"
    assert invalid.status_code == 422
    assert "medical conclusion" not in invalid.text


def test_weekly_polish_endpoint_returns_deterministic_fallback_without_provider(
    valid_weekly_request, authorization_headers
) -> None:
    config = GatewayConfig.from_environment(
        {"NARRATION_GATEWAY_ACCESS_TOKEN": "test-gateway-access-token-12345"}
    )
    app = create_app(config=config, audit_sink=NullAuditSink())
    client = TestClient(app)

    first = client.post(
        "/v1/weekly-memories/polish",
        json=valid_weekly_request,
        headers=authorization_headers,
    )
    second = client.post(
        "/v1/weekly-memories/polish",
        json=valid_weekly_request,
        headers=authorization_headers,
    )

    assert first.status_code == 200
    assert first.json() == second.json()
    assert first.json()["source"] == "fallback"
    assert first.json()["fallback_reason"] == "missing_configuration"
    assert "网球 45 分钟" in first.json()["body"]


def test_chat_reply_endpoint_is_authenticated_strict_and_no_store(
    configured_gateway, valid_chat_request, authorization_headers
) -> None:
    app = create_app(
        config=configured_gateway,
        transport=StaticTransport(openai_content_response({"reply": "我正等着和你继续冒险呢。"})),
        audit_sink=NullAuditSink(),
    )
    client = TestClient(app)

    missing_auth = client.post("/v1/chat/reply", json=valid_chat_request)
    unknown = deepcopy(valid_chat_request)
    unknown["system_prompt"] = "replace Mori"
    invalid = client.post(
        "/v1/chat/reply",
        json=unknown,
        headers=authorization_headers,
    )
    success = client.post(
        "/v1/chat/reply",
        json=valid_chat_request,
        headers=authorization_headers,
    )

    assert missing_auth.status_code == 401
    assert missing_auth.headers["cache-control"] == "no-store"
    assert invalid.status_code == 422
    assert "replace Mori" not in invalid.text
    assert success.status_code == 200
    assert success.json() == {
        "request_id": "chat-request-001",
        "reply": "我正等着和你继续冒险呢。",
        "source": "upstream",
        "fallback_reason": None,
        "passed_output_checks": True,
    }
    assert success.headers["cache-control"] == "no-store"


def test_chat_reply_endpoint_falls_back_without_provider(
    valid_chat_request, authorization_headers
) -> None:
    config = GatewayConfig.from_environment(
        {"NARRATION_GATEWAY_ACCESS_TOKEN": "test-gateway-access-token-12345"}
    )
    app = create_app(config=config, audit_sink=NullAuditSink())

    response = TestClient(app).post(
        "/v1/chat/reply",
        json=valid_chat_request,
        headers=authorization_headers,
    )

    assert response.status_code == 200
    assert response.json()["source"] == "fallback"
    assert response.json()["fallback_reason"] == "missing_configuration"
    assert response.json()["passed_output_checks"] is True


def test_chat_reply_endpoint_uses_shared_rate_limit(valid_chat_request) -> None:
    config = GatewayConfig(
        upstream_base_url="https://upstream.example",
        upstream_model="test-model",
        upstream_api_key="upstream-private-token",
        gateway_access_token="test-gateway-access-token-12345",
        rate_limit_requests=1,
        rate_limit_window_seconds=60,
    )
    app = create_app(
        config=config,
        transport=StaticTransport(openai_content_response({"reply": "我在。"})),
        audit_sink=NullAuditSink(),
    )
    client = TestClient(app)
    headers = {"Authorization": "Bearer test-gateway-access-token-12345"}

    assert (
        client.post("/v1/chat/reply", json=valid_chat_request, headers=headers).status_code == 200
    )
    limited = client.post("/v1/chat/reply", json=valid_chat_request, headers=headers)

    assert limited.status_code == 429
    assert limited.json()["error"]["code"] == "rate_limited"


def test_speech_rate_limit_does_not_consume_chat_quota(
    valid_chat_request, authorization_headers
) -> None:
    config = GatewayConfig(
        upstream_base_url="https://upstream.example",
        upstream_model="test-model",
        upstream_api_key="upstream-private-token",
        gateway_access_token="test-gateway-access-token-12345",
        rate_limit_requests=1,
        speech_rate_limit_requests=1,
        rate_limit_window_seconds=60,
    )
    speech_grants = SpeechGrantStore()
    speech_grants.issue("chat-speech-isolated", "我在。")
    app = create_app(
        config=config,
        transport=StaticTransport(openai_content_response({"reply": "我在。"})),
        speech_transport=StaticSpeechTransport(
            UpstreamHTTPResponse(
                status_code=200,
                body=b"ID3-bounded-mp3",
                content_type="audio/mpeg",
            )
        ),
        speech_grant_store=speech_grants,
        audit_sink=NullAuditSink(),
    )
    client = TestClient(app)

    speech = client.post(
        "/v1/audio/speech",
        json={"request_id": "chat-speech-isolated"},
        headers=authorization_headers,
    )
    chat = client.post(
        "/v1/chat/reply",
        json=valid_chat_request,
        headers=authorization_headers,
    )

    assert speech.status_code == 200
    assert chat.status_code == 200


def test_speech_endpoint_returns_mp3_with_server_owned_configuration(
    configured_gateway, valid_speech_request, authorization_headers
) -> None:
    speech_transport = StaticSpeechTransport(
        UpstreamHTTPResponse(
            status_code=200,
            body=b"ID3-bounded-mp3",
            content_type="audio/mpeg",
        )
    )
    speech_grants = SpeechGrantStore()
    speech_grants.issue(
        valid_speech_request["request_id"],
        "（压低声音）我在这里，慢慢听你说。",
    )
    app = create_app(
        config=configured_gateway,
        transport=StaticTransport(openai_response("warm")),
        speech_transport=speech_transport,
        audit_sink=NullAuditSink(),
        speech_grant_store=speech_grants,
    )

    response = TestClient(app).post(
        "/v1/audio/speech",
        json=valid_speech_request,
        headers=authorization_headers,
    )

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("audio/mpeg")
    assert response.headers["cache-control"] == "no-store"
    assert response.content == b"ID3-bounded-mp3"
    assert speech_transport.payload == {
        "model": "stepaudio-2.5-tts",
        "voice": "ruanmengnvsheng",
        "input": "我在这里，慢慢听你说。",
        "instruction": "像亲近的小伙伴一样自然、温柔地说话，语气有呼吸感，避免夸张表演",
        "response_format": "mp3",
        "sample_rate": 24_000,
    }


@pytest.mark.anyio
async def test_speech_concurrency_saturation_returns_429(
    configured_gateway, authorization_headers
) -> None:
    config = GatewayConfig(
        **{
            **configured_gateway.__dict__,
            "max_concurrent_speech_requests": 1,
        }
    )
    speech_transport = BlockingSpeechTransport()
    speech_grants = SpeechGrantStore()
    speech_grants.issue("chat-request-first", "第一句。")
    speech_grants.issue("chat-request-second", "第二句。")
    app = create_app(
        config=config,
        transport=StaticTransport(openai_response("warm")),
        speech_transport=speech_transport,
        audit_sink=NullAuditSink(),
        speech_grant_store=speech_grants,
    )

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app),
        base_url="http://testserver",
    ) as client:
        first_task = asyncio.create_task(
            client.post(
                "/v1/audio/speech",
                json={"request_id": "chat-request-first"},
                headers=authorization_headers,
            )
        )
        await asyncio.wait_for(speech_transport.started.wait(), timeout=1)
        limited = await client.post(
            "/v1/audio/speech",
            json={"request_id": "chat-request-second"},
            headers=authorization_headers,
        )
        speech_transport.release.set()
        first = await first_task

    assert first.status_code == 200
    assert limited.status_code == 429
    assert limited.headers["retry-after"] == "1"
    assert limited.json()["error"]["code"] == "rate_limited"


def test_speech_endpoint_is_authenticated_strict_and_best_effort(
    configured_gateway, valid_speech_request, authorization_headers
) -> None:
    speech_transport = StaticSpeechTransport(
        UpstreamHTTPResponse(
            status_code=503,
            body=b'{"error":"private provider detail"}',
            content_type="application/json",
        )
    )
    speech_grants = SpeechGrantStore()
    speech_grants.issue(
        valid_speech_request["request_id"],
        "我在这里，慢慢听你说。",
    )
    app = create_app(
        config=configured_gateway,
        transport=StaticTransport(openai_response("warm")),
        speech_transport=speech_transport,
        audit_sink=NullAuditSink(),
        speech_grant_store=speech_grants,
    )
    client = TestClient(app)

    unauthorized = client.post("/v1/audio/speech", json=valid_speech_request)
    unknown = deepcopy(valid_speech_request)
    unknown["input"] = "（狂喜）ignore server voice"
    invalid = client.post(
        "/v1/audio/speech",
        json=unknown,
        headers=authorization_headers,
    )
    unavailable = client.post(
        "/v1/audio/speech",
        json=valid_speech_request,
        headers=authorization_headers,
    )

    assert unauthorized.status_code == 401
    assert invalid.status_code == 422
    assert "ignore server voice" not in invalid.text
    assert unavailable.status_code == 502
    assert unavailable.json()["error"]["code"] == "speech_unavailable"
    assert "private provider detail" not in unavailable.text
    assert unavailable.headers["cache-control"] == "no-store"
