"""Application service that converts every upstream failure into safe copy."""

from __future__ import annotations

import json
from typing import Optional

from pydantic import ValidationError

from .audit import AuditSink, SafeAuditEvent
from .config import GatewayConfig
from .fallback import approved_narration, local_fallback
from .models import (
    FallbackReason,
    GeneratedNarration,
    NarrationRequest,
    NarrationResponse,
    UpstreamChatCompletionResponse,
)
from .prompting import build_chat_payload
from .transport import (
    ChatCompletionTransport,
    UpstreamNetworkError,
    UpstreamResponseTooLarge,
    UpstreamTimeout,
)


class NarrationService:
    def __init__(
        self,
        config: GatewayConfig,
        transport: Optional[ChatCompletionTransport],
        audit_sink: AuditSink,
    ) -> None:
        self._config = config
        self._transport = transport
        self._audit = audit_sink

    async def generate(self, request: NarrationRequest) -> NarrationResponse:
        if not self._config.upstream_ready or self._transport is None:
            return self._fallback(request, FallbackReason.MISSING_CONFIGURATION)

        payload = build_chat_payload(
            request, self._config.upstream_model, self._config.max_narration_characters
        )
        try:
            response = await self._transport.complete(
                payload,
                timeout_seconds=self._config.upstream_timeout_seconds,
                max_response_bytes=self._config.max_upstream_response_bytes,
            )
        except UpstreamTimeout:
            return self._fallback(request, FallbackReason.TIMEOUT)
        except UpstreamResponseTooLarge:
            return self._fallback(request, FallbackReason.RESPONSE_TOO_LARGE)
        except UpstreamNetworkError:
            return self._fallback(request, FallbackReason.NETWORK_ERROR)
        except Exception:
            # Unexpected adapter failures are not allowed to leak data or break
            # the pet interaction. Details stay out of logs by design.
            return self._fallback(request, FallbackReason.INTERNAL_ERROR)

        status_reason = self._status_fallback(response.status_code)
        if status_reason is not None:
            return self._fallback(request, status_reason, response.status_code)
        if len(response.body) > self._config.max_upstream_response_bytes:
            return self._fallback(request, FallbackReason.RESPONSE_TOO_LARGE, response.status_code)

        tone = self._decode_tone(response.body)
        if tone is None:
            return self._fallback(request, FallbackReason.MALFORMED, response.status_code)

        narration = approved_narration(
            request.trigger,
            request.locale,
            tone,
            self._config.max_narration_characters,
        )

        result = NarrationResponse(
            request_id=request.request_id,
            narration=narration.strip(),
            source="upstream",
            fallback_reason=None,
            safe=True,
        )
        self._record(
            SafeAuditEvent(
                request_id=request.request_id,
                outcome="upstream",
                upstream_status=response.status_code,
            )
        )
        return result

    @staticmethod
    def _status_fallback(status_code: int) -> Optional[FallbackReason]:
        if status_code in (401, 403):
            return FallbackReason.UNAUTHORIZED
        if status_code == 429:
            return FallbackReason.RATE_LIMITED
        if 500 <= status_code <= 599:
            return FallbackReason.SERVER_ERROR
        if status_code < 200 or status_code > 299:
            return FallbackReason.CLIENT_ERROR
        return None

    @staticmethod
    def _decode_tone(body: bytes) -> Optional[str]:
        try:
            upstream = UpstreamChatCompletionResponse.model_validate_json(body)
            if upstream.choices[0].message.refusal:
                return None
            generated = GeneratedNarration.model_validate_json(upstream.choices[0].message.content)
            return generated.tone
        except (ValidationError, ValueError, json.JSONDecodeError, UnicodeDecodeError):
            return None

    def _fallback(
        self,
        request: NarrationRequest,
        reason: FallbackReason,
        upstream_status: Optional[int] = None,
    ) -> NarrationResponse:
        result = NarrationResponse(
            request_id=request.request_id,
            narration=local_fallback(
                request.trigger,
                request.locale,
                self._config.max_narration_characters,
            ),
            source="fallback",
            fallback_reason=reason,
            safe=True,
        )
        self._record(
            SafeAuditEvent(
                request_id=request.request_id,
                outcome=reason.value,
                upstream_status=upstream_status,
            )
        )
        return result

    def _record(self, event: SafeAuditEvent) -> None:
        try:
            self._audit.record(event)
        except Exception:
            # Observability must never make the user-facing path unavailable.
            pass
