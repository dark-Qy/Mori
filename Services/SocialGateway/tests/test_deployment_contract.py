from pathlib import Path

GATEWAY_ROOT = Path(__file__).resolve().parents[1]


def test_installer_keeps_wheel_readable_by_the_service_user() -> None:
    installer = (GATEWAY_ROOT / "deploy" / "install-local-service.sh").read_text()

    assert "umask 022" in installer
    assert installer.index("umask 022") < installer.index("pip install --force-reinstall")


def test_service_runs_outside_the_install_root_source_namespace() -> None:
    installer = (GATEWAY_ROOT / "deploy" / "install-local-service.sh").read_text()
    unit = (GATEWAY_ROOT / "deploy" / "social-gateway.service").read_text()

    assert 'install -d -o root -g root -m 0755 "$install_root/runtime"' in installer
    assert "WorkingDirectory=/opt/watch-companion-social-gateway/runtime" in unit
    assert "WorkingDirectory=/opt/watch-companion-social-gateway\n" not in unit


def test_installer_waits_for_the_gateway_health_endpoint() -> None:
    installer = (GATEWAY_ROOT / "deploy" / "install-local-service.sh").read_text()

    assert "for _ in {1..30}" in installer
    assert "sleep 0.5" in installer
    assert "Social Gateway did not become healthy within 15 seconds." in installer
