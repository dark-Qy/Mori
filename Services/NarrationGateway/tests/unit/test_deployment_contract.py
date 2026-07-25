from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from narration_gateway.__main__ import _bind_port

ROOT = Path(__file__).resolve().parents[2]
DEPLOY = ROOT / "deploy"


def test_default_bind_port_avoids_existing_target_services(monkeypatch) -> None:
    monkeypatch.delenv("NARRATION_BIND_PORT", raising=False)

    assert _bind_port() == 8790
    assert _bind_port() not in {8787, 8788}


@pytest.mark.parametrize("value", ["0", "1023", "65536"])
def test_bind_port_override_is_bounded(monkeypatch, value: str) -> None:
    monkeypatch.setenv("NARRATION_BIND_PORT", value)

    with pytest.raises(ValueError):
        _bind_port()


def test_deploy_environment_contains_no_credential() -> None:
    environment = (DEPLOY / "narration-gateway.env.example").read_text()

    assert "NARRATION_UPSTREAM_API_KEY=\n" in environment
    assert "NARRATION_GATEWAY_ACCESS_TOKEN=\n" in environment
    assert "NARRATION_BIND_PORT=8790" in environment
    for line in environment.splitlines():
        if line.startswith(("NARRATION_UPSTREAM_API_KEY=", "NARRATION_GATEWAY_ACCESS_TOKEN=")):
            assert line.endswith("=")


def test_systemd_contract_is_local_hardened_and_separate_from_social_gateway() -> None:
    service = (DEPLOY / "narration-gateway.service").read_text()
    installer = (DEPLOY / "install-local-service.sh").read_text()

    assert "User=narration-gateway" in service
    assert "NoNewPrivileges=true" in service
    assert "ProtectSystem=strict" in service
    assert "/etc/watch-companion/narration-gateway.env" in service
    assert "127.0.0.1:8790/healthz" in installer
    assert "social-gateway.service" not in service
    assert "8788" not in service
    assert "8788" not in installer


def test_nginx_contract_adds_only_ai_namespace_on_port_8790() -> None:
    locations = (DEPLOY / "nginx-ai-locations.conf.template").read_text()

    assert "location = /ai/healthz" in locations
    assert "location = /ai/v1/weekly-memories/polish" in locations
    assert "location ^~ /ai/" in locations
    assert "127.0.0.1:8790" in locations
    assert "127.0.0.1:8788" not in locations
    assert "server_name" not in locations
    assert "proxy_set_header Authorization $http_authorization;" in locations
    assert "proxy_connect_timeout 2s;" in locations
    assert "proxy_read_timeout 12s;" in locations
    assert 'add_header Cache-Control "no-store" always;' in locations
    assert "/ai/v1/narrations" not in locations


def test_smoke_test_requires_a_real_upstream_result() -> None:
    smoke = (DEPLOY / "smoke-test-upstream.sh").read_text()

    assert 'response.get("source") != "upstream"' in smoke
    assert '"source_hash"' in smoke
    assert "NARRATION_SMOKE_TOKEN" in smoke
    assert os.access(DEPLOY / "smoke-test-upstream.sh", os.X_OK)
    assert os.access(DEPLOY / "install-local-service.sh", os.X_OK)


@pytest.mark.parametrize(
    "script",
    [DEPLOY / "install-local-service.sh", DEPLOY / "smoke-test-upstream.sh"],
)
def test_deploy_scripts_have_valid_bash_syntax(script: Path) -> None:
    subprocess.run(["bash", "-n", str(script)], check=True)
