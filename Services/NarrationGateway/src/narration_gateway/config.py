"""Environment-only configuration with conservative, bounded defaults."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import Mapping, Optional
from urllib.parse import urlparse


def _bounded_float(
    environment: Mapping[str, str], name: str, default: float, minimum: float, maximum: float
) -> float:
    raw = environment.get(name)
    value = default if raw is None else float(raw)
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def _bounded_int(
    environment: Mapping[str, str], name: str, default: int, minimum: int, maximum: int
) -> int:
    raw = environment.get(name)
    value = default if raw is None else int(raw)
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


@dataclass(frozen=True)
class GatewayConfig:
    """Runtime configuration. Secret values are excluded from repr output."""

    upstream_base_url: str
    upstream_model: str
    upstream_api_key: Optional[str] = field(default=None, repr=False)
    gateway_access_token: Optional[str] = field(default=None, repr=False)
    upstream_timeout_seconds: float = 8.0
    max_request_bytes: int = 32_768
    max_upstream_response_bytes: int = 16_384
    max_narration_characters: int = 180
    max_weekly_title_characters: int = 24
    max_weekly_body_characters: int = 160
    rate_limit_requests: int = 30
    rate_limit_window_seconds: int = 60

    @property
    def upstream_ready(self) -> bool:
        return bool(self.upstream_api_key and self.upstream_base_url and self.upstream_model)

    @property
    def chat_completions_url(self) -> str:
        return f"{self.upstream_base_url.rstrip('/')}/v1/chat/completions"

    @classmethod
    def from_environment(cls, environment: Optional[Mapping[str, str]] = None) -> "GatewayConfig":
        env = os.environ if environment is None else environment
        base_url = env.get("NARRATION_UPSTREAM_BASE_URL", "https://api.stepfun.com").strip()
        parsed = urlparse(base_url)
        if (
            parsed.scheme != "https"
            or not parsed.netloc
            or parsed.username
            or parsed.password
            or parsed.path not in ("", "/")
            or parsed.params
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError(
                "NARRATION_UPSTREAM_BASE_URL must be an HTTPS origin without credentials"
            )

        model = env.get("NARRATION_UPSTREAM_MODEL", "step-1o-turbo-vision").strip()
        if not re.fullmatch(r"[A-Za-z0-9._:/-]{1,128}", model):
            raise ValueError("NARRATION_UPSTREAM_MODEL contains unsupported characters")

        api_key = env.get("NARRATION_UPSTREAM_API_KEY")
        if api_key is not None:
            api_key = api_key.strip() or None
        if api_key is not None and (
            len(api_key) > 4_096 or any(ord(character) < 32 for character in api_key)
        ):
            raise ValueError("NARRATION_UPSTREAM_API_KEY has an invalid format")

        access_token = env.get("NARRATION_GATEWAY_ACCESS_TOKEN")
        if access_token is not None:
            access_token = access_token.strip() or None
        if access_token is not None and (
            len(access_token) < 24
            or len(access_token) > 4_096
            or any(ord(character) < 33 for character in access_token)
        ):
            raise ValueError(
                "NARRATION_GATEWAY_ACCESS_TOKEN must contain 24-4096 visible characters"
            )

        return cls(
            upstream_base_url=base_url,
            upstream_model=model,
            upstream_api_key=api_key,
            gateway_access_token=access_token,
            upstream_timeout_seconds=_bounded_float(
                env, "NARRATION_UPSTREAM_TIMEOUT_SECONDS", 8.0, 0.25, 8.0
            ),
            max_request_bytes=_bounded_int(
                env, "NARRATION_MAX_REQUEST_BYTES", 32_768, 4_096, 65_536
            ),
            max_upstream_response_bytes=_bounded_int(
                env, "NARRATION_MAX_UPSTREAM_RESPONSE_BYTES", 16_384, 1_024, 65_536
            ),
            max_narration_characters=_bounded_int(env, "NARRATION_MAX_CHARACTERS", 180, 40, 300),
            max_weekly_title_characters=_bounded_int(
                env, "NARRATION_MAX_WEEKLY_TITLE_CHARACTERS", 24, 8, 32
            ),
            max_weekly_body_characters=_bounded_int(
                env, "NARRATION_MAX_WEEKLY_BODY_CHARACTERS", 160, 60, 180
            ),
            rate_limit_requests=_bounded_int(env, "NARRATION_RATE_LIMIT_REQUESTS", 30, 1, 600),
            rate_limit_window_seconds=_bounded_int(
                env, "NARRATION_RATE_LIMIT_WINDOW_SECONDS", 60, 1, 3_600
            ),
        )
