import pytest

from narration_gateway.config import GatewayConfig


def test_configuration_reads_secret_only_from_environment_and_hides_repr() -> None:
    config = GatewayConfig.from_environment(
        {
            "NARRATION_UPSTREAM_BASE_URL": "https://gateway.example",
            "NARRATION_UPSTREAM_MODEL": "model-a",
            "NARRATION_UPSTREAM_API_KEY": "extremely-secret",
            "NARRATION_GATEWAY_ACCESS_TOKEN": "gateway-secret-with-24-characters",
            "NARRATION_MAX_CHAT_REPLY_CHARACTERS": "100",
            "NARRATION_MAX_WEEKLY_TITLE_CHARACTERS": "20",
            "NARRATION_MAX_WEEKLY_BODY_CHARACTERS": "140",
        }
    )

    assert config.upstream_ready is True
    assert config.chat_completions_url == "https://gateway.example/v1/chat/completions"
    assert "extremely-secret" not in repr(config)
    assert "gateway-secret-with-24-characters" not in repr(config)
    assert config.max_chat_reply_characters == 100
    assert config.max_weekly_title_characters == 20
    assert config.max_weekly_body_characters == 140


def test_missing_key_keeps_gateway_startable_for_deterministic_fallback() -> None:
    config = GatewayConfig.from_environment({})

    assert config.upstream_ready is False
    assert config.upstream_api_key is None
    assert config.gateway_access_token is None


@pytest.mark.parametrize(
    "environment",
    [
        {"NARRATION_UPSTREAM_BASE_URL": "http://gateway.example"},
        {"NARRATION_UPSTREAM_BASE_URL": "https://user:password@gateway.example"},
        {"NARRATION_UPSTREAM_BASE_URL": "https://gateway.example/custom-path"},
        {"NARRATION_UPSTREAM_MODEL": "bad model\nname"},
        {"NARRATION_UPSTREAM_API_KEY": "invalid\nkey"},
        {"NARRATION_GATEWAY_ACCESS_TOKEN": "too-short"},
        {"NARRATION_GATEWAY_ACCESS_TOKEN": "invalid token with spaces 123"},
        {"NARRATION_UPSTREAM_TIMEOUT_SECONDS": "20"},
        {"NARRATION_MAX_REQUEST_BYTES": "100"},
        {"NARRATION_MAX_CHAT_REPLY_CHARACTERS": "20"},
        {"NARRATION_MAX_WEEKLY_TITLE_CHARACTERS": "40"},
        {"NARRATION_MAX_WEEKLY_BODY_CHARACTERS": "40"},
        {"NARRATION_RATE_LIMIT_REQUESTS": "0"},
    ],
)
def test_invalid_or_unsafe_configuration_is_rejected(environment: dict) -> None:
    with pytest.raises(ValueError):
        GatewayConfig.from_environment(environment)
