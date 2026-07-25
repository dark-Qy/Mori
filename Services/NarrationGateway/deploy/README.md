# Narration Gateway single-server deployment

This deployment adds a private AI proxy beside the existing SocialGateway:

```text
https://social.bsti.online/ai/*
        |
        v
existing Nginx on 80/443
        |
        v
127.0.0.1:8790
        |
        v
systemd narration-gateway.service
```

Port `8790` is intentional. On the target host, `8787` is already occupied by
an unrelated `agent` process and `8788` belongs to SocialGateway. The
NarrationGateway remains bound to localhost.

## 1. Build and upload

From `Services/NarrationGateway`:

```bash
python3 -m pip wheel --no-deps --wheel-dir dist .
```

Upload the wheel and `deploy/` directory. On Debian, install runtime packages
if they are not already present:

```bash
apt-get update
apt-get install -y python3 python3-venv curl nginx
```

Install the service:

```bash
chmod +x deploy/install-local-service.sh deploy/smoke-test-upstream.sh
deploy/install-local-service.sh \
  dist/watch_companion_narration_gateway-0.1.0-py3-none-any.whl
```

The installer creates the `narration-gateway` system user, installs an isolated
venv below `/opt/watch-companion-narration-gateway`, loads secrets from
`/etc/watch-companion/narration-gateway.env`, enables systemd, and verifies
`http://127.0.0.1:8790/healthz`.

## 2. Configure provider and gateway credentials

Edit `/etc/watch-companion/narration-gateway.env` as root. Set a current
OpenAI-compatible text provider origin, model, provider key, and a distinct
gateway bearer token:

```text
NARRATION_UPSTREAM_BASE_URL=https://provider.example
NARRATION_UPSTREAM_MODEL=provider-model
NARRATION_UPSTREAM_API_KEY=server-only-provider-secret
NARRATION_GATEWAY_ACCESS_TOKEN=distinct-random-gateway-token
```

Never reuse the StepFun image key that appeared in chat. It must be treated as
exposed and rotated; it is also the wrong capability for this text endpoint.
Provider keys stay only in the root-owned server environment and are never
placed in the Apple bundle, repository, command line, or smoke-test output.

After editing:

```bash
chown root:narration-gateway /etc/watch-companion/narration-gateway.env
chmod 0640 /etc/watch-companion/narration-gateway.env
systemctl restart narration-gateway.service
curl --fail http://127.0.0.1:8790/healthz
```

## 3. Add `/ai/` to the existing Nginx server

Install the rate-limit declaration in the Nginx `http` context:

```bash
install -o root -g root -m 0644 \
  deploy/nginx-ai-rate-limit.conf.template \
  /etc/nginx/conf.d/narration-gateway-rate-limit.conf
install -o root -g root -m 0644 \
  deploy/nginx-ai-locations.conf.template \
  /etc/nginx/snippets/narration-gateway-locations.conf
```

Inside the existing `server_name social.bsti.online;` block, add this include
before its catch-all `location /`:

```nginx
include /etc/nginx/snippets/narration-gateway-locations.conf;
```

Then validate before reloading:

```bash
nginx -t
systemctl reload nginx
curl --fail https://social.bsti.online/healthz
curl --fail https://social.bsti.online/ai/healthz
```

The existing `/healthz` and `/v1/` routes still point to SocialGateway. Only
`/ai/healthz`, `/ai/v1/weekly-memories/polish`, and `/ai/v1/chat/reply` are
public. The generic narration endpoint, `/ai/openapi.json`, and all other
`/ai/` paths return 404. Both product routes explicitly forward Authorization,
use bounded proxy timeouts, and force `Cache-Control: no-store`. Chat request
and response text stays out of application audit logs, but is necessarily sent
to the configured provider to produce a reply.

## 4. Prove a real upstream response

An HTTP 200 is not enough because provider failures intentionally return local
copy. Run the smoke test with the gateway token supplied through an ephemeral
environment variable:

```bash
read -rsp "Gateway token: " NARRATION_SMOKE_TOKEN
export NARRATION_SMOKE_TOKEN
echo
deploy/smoke-test-upstream.sh
unset NARRATION_SMOKE_TOKEN
```

The script fails unless health says the provider is configured and the weekly
response has `source: "upstream"`, `safe: true`, and the original
`source_hash`. It does not print the token or generated health copy.

## Boundary

This is a small private-integration deployment. The static gateway token is not
multi-user production authentication. A public launch still requires
short-lived account/device credentials, device attestation, distributed quotas,
provider retention review, monitoring, and token rotation. When credentials or
the provider are unavailable, the endpoint deliberately returns deterministic
local copy with `source: "fallback"`.
