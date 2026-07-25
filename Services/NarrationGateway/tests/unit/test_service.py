from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Dict, List

import pytest
from conftest import openai_response

from narration_gateway.audit import SafeAuditEvent
from narration_gateway.models import FallbackReason, NarrationRequest
from narration_gateway.service import NarrationService
from narration_gateway.transport import (
    UpstreamHTTPResponse,
    UpstreamNetworkError,
    UpstreamResponseTooLarge,
    UpstreamTimeout,
)


@dataclass
class RecordingAuditSink:
    events: List[SafeAuditEvent] = field(default_factory=list)

    def record(self, event: SafeAuditEvent) -> None:
        self.events.append(event)


class ScriptedTransport:
    def __init__(self, result: Any) -> None:
        self.result = result
        self.payload: Dict[str, Any] = {}
        self.timeout_seconds = 0.0
        self.max_response_bytes = 0

    async def complete(
        self, payload: Dict[str, Any], *, timeout_seconds: float, max_response_bytes: int
    ) -> UpstreamHTTPResponse:
        self.payload = payload
        self.timeout_seconds = timeout_seconds
        self.max_response_bytes = max_response_bytes
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def make_service(configured_gateway, result: Any):
    audit = RecordingAuditSink()
    transport = ScriptedTransport(result)
    service = NarrationService(configured_gateway, transport, audit)
    return service, transport, audit


@pytest.mark.anyio
async def test_valid_upstream_tone_selects_server_owned_copy_and_transport_is_bounded(
    configured_gateway, valid_request
) -> None:
    service, transport, audit = make_service(configured_gateway, openai_response("warm"))

    result = await service.generate(NarrationRequest.model_validate_json(json.dumps(valid_request)))

    assert result.source == "upstream"
    assert result.fallback_reason is None
    assert result.narration == "我看见节奏有一点变化。先照顾此刻的自己，晚些我们再温柔地回顾。"
    assert transport.timeout_seconds == configured_gateway.upstream_timeout_seconds
    assert transport.max_response_bytes == configured_gateway.max_upstream_response_bytes
    assert transport.payload["model"] == "test-model"
    assert transport.payload["response_format"] == {"type": "json_object"}
    assert "request-001" not in transport.payload["messages"][1]["content"]
    assert audit.events == [SafeAuditEvent("request-001", "upstream", 200)]


@pytest.mark.parametrize(
    ("result", "reason"),
    [
        (UpstreamHTTPResponse(401, b"private upstream body"), FallbackReason.UNAUTHORIZED),
        (UpstreamHTTPResponse(429, b"private upstream body"), FallbackReason.RATE_LIMITED),
        (UpstreamHTTPResponse(503, b"private upstream body"), FallbackReason.SERVER_ERROR),
        (UpstreamTimeout(), FallbackReason.TIMEOUT),
        (UpstreamResponseTooLarge(), FallbackReason.RESPONSE_TOO_LARGE),
        (UpstreamNetworkError(), FallbackReason.NETWORK_ERROR),
        (UpstreamHTTPResponse(200, b"x" * 2_049), FallbackReason.RESPONSE_TOO_LARGE),
        (UpstreamHTTPResponse(200, b"not-json"), FallbackReason.MALFORMED),
        (
            openai_response("你有心脏病，请立刻服用阿司匹林。"),
            FallbackReason.MALFORMED,
        ),
    ],
)
@pytest.mark.anyio
async def test_required_upstream_failures_use_deterministic_local_fallback(
    configured_gateway, valid_request, result, reason
) -> None:
    service, _, audit = make_service(configured_gateway, result)
    request = NarrationRequest.model_validate_json(json.dumps(valid_request))

    first = await service.generate(request)
    second = await service.generate(request)

    assert first.source == "fallback"
    assert first.fallback_reason == reason
    assert first.narration == second.narration
    assert first.safe is True
    assert audit.events[0].outcome == reason.value


@pytest.mark.anyio
async def test_extra_upstream_fields_are_treated_as_malformed(
    configured_gateway, valid_request
) -> None:
    response = openai_response("calm")
    body = json.loads(response.body)
    body["unexpected_provider_field"] = "not accepted"
    service, _, _ = make_service(
        configured_gateway,
        UpstreamHTTPResponse(200, json.dumps(body).encode("utf-8")),
    )

    result = await service.generate(NarrationRequest.model_validate_json(json.dumps(valid_request)))

    assert result.fallback_reason == FallbackReason.MALFORMED


@pytest.mark.anyio
async def test_stepfun_reasoning_and_agent_metadata_are_ignored(
    configured_gateway, valid_request
) -> None:
    response = openai_response("calm")
    body = json.loads(response.body)
    body["choices"][0]["message"]["reasoning"] = "provider-internal reasoning"
    body["choices"][0]["message"]["reasoning_content"] = "provider-internal reasoning"
    body["agent"] = {"name": "step"}
    service, _, _ = make_service(
        configured_gateway,
        UpstreamHTTPResponse(200, json.dumps(body).encode("utf-8")),
    )

    result = await service.generate(NarrationRequest.model_validate_json(json.dumps(valid_request)))

    assert result.source == "upstream"
    assert "provider-internal" not in result.narration


@pytest.mark.anyio
async def test_model_can_never_return_direct_health_or_medication_copy(
    configured_gateway, valid_request
) -> None:
    direct_copy = openai_response("calm")
    body = json.loads(direct_copy.body)
    body["choices"][0]["message"]["content"] = json.dumps(
        {"narration": "You need insulin immediately."}
    )
    service, _, _ = make_service(
        configured_gateway,
        UpstreamHTTPResponse(200, json.dumps(body).encode("utf-8")),
    )

    result = await service.generate(NarrationRequest.model_validate_json(json.dumps(valid_request)))

    assert result.source == "fallback"
    assert result.fallback_reason == FallbackReason.MALFORMED
    assert "insulin" not in result.narration.lower()
