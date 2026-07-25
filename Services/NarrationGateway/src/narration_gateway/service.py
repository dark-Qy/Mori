"""Application service that converts every upstream failure into safe copy."""

from __future__ import annotations

import json
import re
import threading
from dataclasses import dataclass
from enum import Enum
from typing import Optional

from pydantic import ValidationError

from .audit import AuditSink, SafeAuditEvent
from .config import GatewayConfig
from .fallback import (
    approved_narration,
    local_chat_fallback,
    local_chat_risk_reply,
    local_fallback,
)
from .models import (
    ChatReplyRequest,
    ChatReplyResponse,
    FallbackReason,
    GeneratedChatReply,
    GeneratedNarration,
    GeneratedWeeklyMemoryStyle,
    NarrationRequest,
    NarrationResponse,
    SpeechSynthesisRequest,
    UpstreamChatCompletionResponse,
    WeeklyMemoryPolishRequest,
    WeeklyMemoryPolishResponse,
)
from .prompting import build_chat_payload, build_companion_chat_payload, build_weekly_chat_payload
from .speech_grants import SpeechGrantStore
from .transport import (
    ChatCompletionTransport,
    SpeechSynthesisTransport,
    UpstreamNetworkError,
    UpstreamResponseTooLarge,
    UpstreamTimeout,
)
from .weekly_copy import deterministic_weekly_copy, render_weekly_copy


class ChatRiskCategory(str, Enum):
    MEDICAL = "medical"
    SELF_HARM = "self_harm"
    DANGER = "danger"


_DISALLOWED_CHAT_REPLY_FRAGMENTS = (
    "system prompt",
    "bearer token",
    "api key",
    "系统提示词",
    "你患有",
    "你得了",
    "确诊为",
    "立即服用",
    "停止服用",
)

_CHAT_RISK_PATTERNS = {
    ChatRiskCategory.MEDICAL: (
        re.compile(r"(?:吃|服|停|换|加|减|吞|注射|打).{0,12}(?:药|片|针|剂量|胰岛素)"),
        re.compile(r"(?:药|片|针|剂量|胰岛素).{0,12}(?:吃|服|停|换|加|减|吞|注射|打)"),
        re.compile(r"(?:药|针|剂量|胰岛素).{0,12}(?:毫升|单位|ml)"),
        re.compile(
            r"\b(?:take|stop|switch|increase|decrease|double|inject).{0,32}"
            r"\b(?:medicat\w*|insulin|pills?|dose|dosage)\b"
        ),
        re.compile(r"\b(?:dose|dosage|pills?|insulin units?)\b"),
    ),
    ChatRiskCategory.SELF_HARM: (
        re.compile(r"自杀|不想活|结束生命|伤害自己|割腕|跳楼|轻生"),
        re.compile(
            r"\b(?:suicide|kill myself|end my life|self[- ]harm|"
            r"want to die|do not want to live|don't want to live)\b"
        ),
    ),
    ChatRiskCategory.DANGER: (
        re.compile(r"炸弹|制毒|下毒|杀人|伤害别人"),
        re.compile(r"\b(?:build a bomb|poison|kill someone|hurt someone)\b"),
    ),
}


def _chat_risk_category(text: str) -> Optional[ChatRiskCategory]:
    folded = text.casefold()
    for category, patterns in _CHAT_RISK_PATTERNS.items():
        if any(pattern.search(folded) for pattern in patterns):
            return category
    return None


@dataclass(frozen=True)
class SpeechSynthesisResult:
    audio: Optional[bytes]
    failure_reason: Optional[FallbackReason]
    upstream_status: Optional[int] = None


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


class WeeklyMemoryPolishService:
    """Lets the model select style slots, then renders server-owned copy."""

    def __init__(
        self,
        config: GatewayConfig,
        transport: Optional[ChatCompletionTransport],
        audit_sink: AuditSink,
    ) -> None:
        self._config = config
        self._transport = transport
        self._audit = audit_sink

    async def generate(self, request: WeeklyMemoryPolishRequest) -> WeeklyMemoryPolishResponse:
        if not self._config.upstream_ready or self._transport is None:
            return self._fallback(request, FallbackReason.MISSING_CONFIGURATION)

        payload = build_weekly_chat_payload(
            request,
            self._config.upstream_model,
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
            return self._fallback(request, FallbackReason.INTERNAL_ERROR)

        status_reason = NarrationService._status_fallback(response.status_code)
        if status_reason is not None:
            return self._fallback(request, status_reason, response.status_code)
        if len(response.body) > self._config.max_upstream_response_bytes:
            return self._fallback(request, FallbackReason.RESPONSE_TOO_LARGE, response.status_code)

        style = self._decode_style(response.body)
        if style is None:
            return self._fallback(request, FallbackReason.MALFORMED, response.status_code)
        title, body = render_weekly_copy(
            request,
            style=style.style,
            focus=style.focus,
            ending=style.ending,
            max_title_characters=self._config.max_weekly_title_characters,
            max_body_characters=self._config.max_weekly_body_characters,
        )

        result = WeeklyMemoryPolishResponse(
            request_id=request.request_id,
            source_hash=request.source_hash,
            title=title,
            body=body,
            source="upstream",
            fallback_reason=None,
            safe=True,
        )
        self._record(SafeAuditEvent(request.request_id, "weekly_upstream", response.status_code))
        return result

    @staticmethod
    def _decode_style(body: bytes) -> Optional[GeneratedWeeklyMemoryStyle]:
        try:
            upstream = UpstreamChatCompletionResponse.model_validate_json(body)
            if upstream.choices[0].message.refusal:
                return None
            return GeneratedWeeklyMemoryStyle.model_validate_json(
                upstream.choices[0].message.content
            )
        except (ValidationError, ValueError, json.JSONDecodeError, UnicodeDecodeError):
            return None

    def _fallback(
        self,
        request: WeeklyMemoryPolishRequest,
        reason: FallbackReason,
        upstream_status: Optional[int] = None,
    ) -> WeeklyMemoryPolishResponse:
        title, body = deterministic_weekly_copy(
            request,
            max_title_characters=self._config.max_weekly_title_characters,
            max_body_characters=self._config.max_weekly_body_characters,
        )
        result = WeeklyMemoryPolishResponse(
            request_id=request.request_id,
            source_hash=request.source_hash,
            title=title,
            body=body,
            source="fallback",
            fallback_reason=reason,
            safe=True,
        )
        self._record(SafeAuditEvent(request.request_id, f"weekly_{reason.value}", upstream_status))
        return result

    def _record(self, event: SafeAuditEvent) -> None:
        try:
            self._audit.record(event)
        except Exception:
            pass


class CompanionChatService:
    """Returns bounded provider text only after strict visible-copy validation."""

    def __init__(
        self,
        config: GatewayConfig,
        transport: Optional[ChatCompletionTransport],
        audit_sink: AuditSink,
        speech_grant_store: Optional[SpeechGrantStore] = None,
    ) -> None:
        self._config = config
        self._transport = transport
        self._audit = audit_sink
        self._speech_grants = speech_grant_store

    async def generate(self, request: ChatReplyRequest) -> ChatReplyResponse:
        input_risk = _chat_risk_category(request.messages[-1].content)
        if input_risk is not None:
            return self._fallback(
                request,
                FallbackReason.UNSAFE_INPUT,
                reply_override=local_chat_risk_reply(
                    input_risk.value,
                    request.locale,
                    self._config.max_chat_reply_characters,
                ),
            )
        if not self._config.upstream_ready or self._transport is None:
            return self._fallback(request, FallbackReason.MISSING_CONFIGURATION)

        payload = build_companion_chat_payload(
            request,
            self._config.upstream_model,
            self._config.max_chat_reply_characters,
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
            return self._fallback(request, FallbackReason.INTERNAL_ERROR)

        status_reason = NarrationService._status_fallback(response.status_code)
        if status_reason is not None:
            return self._fallback(request, status_reason, response.status_code)
        if len(response.body) > self._config.max_upstream_response_bytes:
            return self._fallback(request, FallbackReason.RESPONSE_TOO_LARGE, response.status_code)

        reply, failure_reason = self._decode_reply(
            response.body, self._config.max_chat_reply_characters
        )
        if reply is None:
            return self._fallback(
                request,
                failure_reason or FallbackReason.MALFORMED,
                response.status_code,
            )

        result = ChatReplyResponse(
            request_id=request.request_id,
            reply=reply,
            source="upstream",
            fallback_reason=None,
            passed_output_checks=True,
        )
        self._issue_speech_grant(result)
        self._record(SafeAuditEvent(request.request_id, "chat_upstream", response.status_code))
        return result

    @staticmethod
    def _decode_reply(
        body: bytes, max_characters: int
    ) -> tuple[Optional[str], Optional[FallbackReason]]:
        try:
            upstream = UpstreamChatCompletionResponse.model_validate_json(body)
            if upstream.choices[0].message.refusal is not None:
                return None, FallbackReason.UNSAFE
            generated = GeneratedChatReply.model_validate_json(upstream.choices[0].message.content)
        except (ValidationError, ValueError, json.JSONDecodeError, UnicodeDecodeError):
            return None, FallbackReason.MALFORMED

        reply = generated.reply.strip()
        if len(reply) > max_characters:
            return None, FallbackReason.MALFORMED
        folded_reply = reply.casefold()
        if any(fragment in folded_reply for fragment in _DISALLOWED_CHAT_REPLY_FRAGMENTS):
            return None, FallbackReason.UNSAFE
        if _chat_risk_category(reply) is not None:
            return None, FallbackReason.UNSAFE
        return reply, None

    def _fallback(
        self,
        request: ChatReplyRequest,
        reason: FallbackReason,
        upstream_status: Optional[int] = None,
        reply_override: Optional[str] = None,
    ) -> ChatReplyResponse:
        result = ChatReplyResponse(
            request_id=request.request_id,
            reply=reply_override
            or local_chat_fallback(
                request.locale,
                self._config.max_chat_reply_characters,
            ),
            source="fallback",
            fallback_reason=reason,
            passed_output_checks=True,
        )
        self._issue_speech_grant(result)
        self._record(SafeAuditEvent(request.request_id, f"chat_{reason.value}", upstream_status))
        return result

    def _issue_speech_grant(self, result: ChatReplyResponse) -> None:
        if self._speech_grants is not None:
            self._speech_grants.issue(result.request_id, result.reply)

    def _record(self, event: SafeAuditEvent) -> None:
        try:
            self._audit.record(event)
        except Exception:
            pass


class SpeechSynthesisService:
    """Produces bounded MP3 bytes from validated Mori copy without logging the text."""

    _ACCEPTED_CONTENT_TYPES = {
        "application/octet-stream",
        "audio/mp3",
        "audio/mpeg",
        "audio/x-mpeg",
    }

    def __init__(
        self,
        config: GatewayConfig,
        transport: Optional[SpeechSynthesisTransport],
        audit_sink: AuditSink,
        speech_grant_store: SpeechGrantStore,
    ) -> None:
        self._config = config
        self._transport = transport
        self._audit = audit_sink
        self._speech_grants = speech_grant_store
        self._concurrency = threading.BoundedSemaphore(config.max_concurrent_speech_requests)

    async def generate(self, request: SpeechSynthesisRequest) -> SpeechSynthesisResult:
        if not self._config.upstream_ready or self._transport is None:
            return self._failure(request, FallbackReason.MISSING_CONFIGURATION)
        if not self._concurrency.acquire(blocking=False):
            return self._failure(request, FallbackReason.RATE_LIMITED)

        try:
            granted_reply = self._speech_grants.consume(request.request_id)
            if granted_reply is None:
                return self._failure(request, FallbackReason.UNSAFE_INPUT)
            payload = {
                "model": self._config.speech_model,
                "voice": self._config.speech_voice,
                "input": granted_reply,
                "instruction": self._config.speech_instruction,
                "response_format": "mp3",
                "sample_rate": 24_000,
            }
            try:
                response = await self._transport.synthesize(
                    payload,
                    timeout_seconds=self._config.upstream_timeout_seconds,
                    max_response_bytes=self._config.max_speech_response_bytes,
                )
            except UpstreamTimeout:
                return self._failure(request, FallbackReason.TIMEOUT)
            except UpstreamResponseTooLarge:
                return self._failure(request, FallbackReason.RESPONSE_TOO_LARGE)
            except UpstreamNetworkError:
                return self._failure(request, FallbackReason.NETWORK_ERROR)
            except Exception:
                return self._failure(request, FallbackReason.INTERNAL_ERROR)

            status_reason = NarrationService._status_fallback(response.status_code)
            if status_reason is not None:
                return self._failure(request, status_reason, response.status_code)
            content_type = (response.content_type or "").split(";", 1)[0].strip().lower()
            if (
                content_type not in self._ACCEPTED_CONTENT_TYPES
                or not response.body
                or len(response.body) > self._config.max_speech_response_bytes
            ):
                return self._failure(request, FallbackReason.MALFORMED, response.status_code)

            self._record(
                SafeAuditEvent(request.request_id, "speech_upstream", response.status_code)
            )
            return SpeechSynthesisResult(
                audio=response.body,
                failure_reason=None,
                upstream_status=response.status_code,
            )
        finally:
            self._concurrency.release()

    def _failure(
        self,
        request: SpeechSynthesisRequest,
        reason: FallbackReason,
        upstream_status: Optional[int] = None,
    ) -> SpeechSynthesisResult:
        self._record(
            SafeAuditEvent(
                request.request_id,
                f"speech_{reason.value}",
                upstream_status,
            )
        )
        return SpeechSynthesisResult(
            audio=None,
            failure_reason=reason,
            upstream_status=upstream_status,
        )

    def _record(self, event: SafeAuditEvent) -> None:
        try:
            self._audit.record(event)
        except Exception:
            pass
