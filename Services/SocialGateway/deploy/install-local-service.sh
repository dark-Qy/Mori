#!/usr/bin/env bash

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

if [[ $# -ne 1 || ! -f $1 ]]; then
  echo "Usage: $0 /path/to/watch_companion_social_gateway-*.whl" >&2
  exit 1
fi

# Package files are not secrets and must remain readable by the service user,
# even when the caller uses a restrictive deployment umask.
umask 022

bundle_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
wheel_path=$(realpath "$1")
service_user=social-gateway
install_root=/opt/watch-companion-social-gateway
config_root=/etc/watch-companion

if ! id "$service_user" >/dev/null 2>&1; then
  useradd \
    --system \
    --user-group \
    --home-dir "$install_root" \
    --shell /usr/sbin/nologin \
    "$service_user"
fi

install -d -o root -g root -m 0755 "$install_root"
install -d -o root -g root -m 0755 "$install_root/runtime"
install -d -o root -g "$service_user" -m 0750 "$config_root"

if [[ ! -x "$install_root/venv/bin/python" ]]; then
  python3 -m venv "$install_root/venv"
fi

"$install_root/venv/bin/python" -m pip install --upgrade pip
"$install_root/venv/bin/python" -m pip install --force-reinstall "$wheel_path"
"$install_root/venv/bin/python" -m pip freeze \
  >"$install_root/requirements.deployed.txt"

if [[ ! -f "$config_root/social-gateway.env" ]]; then
  install \
    -o root \
    -g "$service_user" \
    -m 0640 \
    "$bundle_dir/social-gateway.env.example" \
    "$config_root/social-gateway.env"
fi

install \
  -o root \
  -g root \
  -m 0644 \
  "$bundle_dir/social-gateway.service" \
  /etc/systemd/system/social-gateway.service

systemctl daemon-reload
systemctl enable social-gateway.service
systemctl restart social-gateway.service

health_payload=
for _ in {1..30}; do
  if health_payload=$(curl --fail --silent http://127.0.0.1:8788/healthz); then
    break
  fi
  sleep 0.5
done

if [[ -z $health_payload ]]; then
  systemctl --no-pager --full status social-gateway.service || true
  journalctl -u social-gateway.service -n 50 --no-pager || true
  echo "Social Gateway did not become healthy within 15 seconds." >&2
  exit 1
fi

systemctl is-active social-gateway.service
echo "$health_payload"
