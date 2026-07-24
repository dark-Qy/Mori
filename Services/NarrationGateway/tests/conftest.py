from __future__ import annotations

import json
from typing import Any, Dict

import pytest

from narration_gateway.config import GatewayConfig
from narration_gateway.transport import UpstreamHTTPResponse


@pytest.fixture
def valid_request() -> Dict[str, Any]:
    return {
        "request_id": "request-001",
        "locale": "zh-CN",
        "trigger": "rule_hit",
        "pet": {"name": "芽芽", "mood": "concerned", "level": 8, "bond": 42},
        "health": {
            "sleep": {
                "last_night_minutes": 390,
                "efficiency_percent": 88.0,
                "awakenings": 2,
                "baseline_delta_minutes": -35,
                "trend_14d": "stable",
                "last_night_stages": [
                    {"stage": "core", "start_offset_minutes": 0, "duration_minutes": 90},
                    {"stage": "deep", "start_offset_minutes": 90, "duration_minutes": 50},
                    {"stage": "rem", "start_offset_minutes": 140, "duration_minutes": 35},
                ],
            },
            "heart": {
                "resting_bpm": 62.0,
                "baseline_resting_bpm": 60.0,
                "trend": "stable",
            },
            "activity": {
                "steps": 7200,
                "active_minutes": 34,
                "workouts": [{"kind": "football", "duration_minutes": 45}],
            },
            "baseline": {
                "days": 30,
                "average_sleep_minutes": 425,
                "average_resting_bpm": 60.0,
                "average_steps": 6800,
            },
            "daily_history": [
                {
                    "day_offset": 0,
                    "sleep_minutes": 390,
                    "resting_bpm": 62.0,
                    "steps": 7200,
                    "active_minutes": 34,
                },
                {
                    "day_offset": 1,
                    "sleep_minutes": 420,
                    "resting_bpm": 60.0,
                    "steps": 6500,
                    "active_minutes": 28,
                },
            ],
        },
        "rule_hits": [
            {
                "rule_id": "sleep-below-baseline",
                "kind": "attention",
                "summary": "昨晚睡眠低于个人基线，但不是医疗结论。",
            }
        ],
        "story": {
            "mainline_chapter": 3,
            "recent_event": "在雾林找到了一枚种子。",
            "side_quest": "今晚提前放下屏幕。",
        },
        "schedule_context": "明早有一个普通日程。",
    }


@pytest.fixture
def valid_weekly_request() -> Dict[str, Any]:
    return {
        "request_id": "weekly-request-001",
        "source_hash": "weekly.source:abc12345",
        "locale": "zh-CN",
        "activities": [
            {"kind": "tennis", "duration_minutes": 45},
            {"kind": "swimming", "duration_minutes": 60},
        ],
        "total_steps": 42350,
        "active_minutes": 210,
        "average_sleep_minutes": 435,
        "personality": {
            "voice": "warm",
            "pace": "balanced",
            "themes": ["racket_sports", "water_sports"],
        },
    }


@pytest.fixture
def configured_gateway() -> GatewayConfig:
    return GatewayConfig(
        upstream_base_url="https://upstream.example",
        upstream_model="test-model",
        upstream_api_key="test-secret-never-log",
        gateway_access_token="test-gateway-access-token-12345",
        upstream_timeout_seconds=1.25,
        max_request_bytes=8_192,
        max_upstream_response_bytes=2_048,
        max_narration_characters=180,
    )


@pytest.fixture
def authorization_headers() -> Dict[str, str]:
    return {"Authorization": "Bearer test-gateway-access-token-12345"}


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


def openai_response(tone: str) -> UpstreamHTTPResponse:
    return openai_content_response({"tone": tone})


def openai_content_response(content_value: Dict[str, Any]) -> UpstreamHTTPResponse:
    content = json.dumps(content_value, ensure_ascii=False)
    body = json.dumps(
        {
            "id": "completion-1",
            "object": "chat.completion",
            "created": 1,
            "model": "test-model",
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": content, "refusal": None},
                    "finish_reason": "stop",
                    "logprobs": None,
                }
            ],
            "usage": {"prompt_tokens": 10, "completion_tokens": 8, "total_tokens": 18},
            "system_fingerprint": None,
            "service_tier": None,
        },
        ensure_ascii=False,
    ).encode("utf-8")
    return UpstreamHTTPResponse(status_code=200, body=body)
