import json
import logging

import pytest

from narration_gateway.audit import SafeAuditEvent, StructuredAuditSink
from narration_gateway.models import NarrationRequest
from narration_gateway.service import NarrationService
from narration_gateway.transport import UpstreamHTTPResponse


class SensitiveFailureTransport:
    async def complete(self, payload, *, timeout_seconds, max_response_bytes):
        del payload, timeout_seconds, max_response_bytes
        return UpstreamHTTPResponse(status_code=401, body=b"private-health-body")


def test_structured_audit_contains_only_safe_metadata(caplog) -> None:
    caplog.set_level(logging.INFO, logger="narration_gateway.audit")
    sink = StructuredAuditSink()

    sink.record(SafeAuditEvent("request-privacy", "upstream_unauthorized", 401))

    output = caplog.text
    assert "request-privacy" in output
    assert "upstream_unauthorized" in output
    assert "Authorization" not in output
    assert "Bearer" not in output
    assert "sleep" not in output
    assert "heart" not in output


@pytest.mark.anyio
async def test_service_logs_neither_configuration_secret_nor_health_body(
    caplog, configured_gateway, valid_request
) -> None:
    caplog.set_level(logging.INFO, logger="narration_gateway.audit")
    valid_request["rule_hits"][0]["summary"] = "uniquely-sensitive-health-summary"
    service = NarrationService(
        configured_gateway,
        SensitiveFailureTransport(),
        StructuredAuditSink(),
    )

    await service.generate(NarrationRequest.model_validate_json(json.dumps(valid_request)))

    assert "test-secret-never-log" not in caplog.text
    assert "uniquely-sensitive-health-summary" not in caplog.text
    assert "private-health-body" not in caplog.text
    assert "Authorization" not in caplog.text
