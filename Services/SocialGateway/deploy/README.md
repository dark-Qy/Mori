# Single-server integration deployment

This deployment shape is for physical-device integration and a small private
test:

```text
social.example.com:443
        |
        v
Nginx + Let's Encrypt
        |
        v
127.0.0.1:8788
        |
        v
systemd, one SocialGateway process
```

It is deliberately single-process because the current rendezvous store is
in-memory. A service restart drops active sessions, and multiple workers would
create independent matching pools.

## 1. Build an immutable application artifact

From `Services/SocialGateway`:

```bash
python3 -m pip wheel --no-deps --wheel-dir dist .
```

Upload the wheel and this `deploy` directory to the server. A standard Debian
host needs these packages:

```bash
apt-get update
apt-get install -y python3 python3-venv curl nginx certbot python3-certbot-nginx
```

## 2. Install the private localhost service

The server needs Python 3.9 or newer and the `venv` module. From the uploaded
directory:

```bash
chmod +x deploy/install-local-service.sh
deploy/install-local-service.sh \
  dist/watch_companion_social_gateway-0.1.0-py3-none-any.whl
```

The installer:

- creates the `social-gateway` system user;
- installs into `/opt/watch-companion-social-gateway/venv`;
- starts from the empty `/opt/watch-companion-social-gateway/runtime` directory so a legacy source
  checkout cannot shadow the installed wheel;
- stores the resolved dependency versions in
  `/opt/watch-companion-social-gateway/requirements.deployed.txt`;
- loads bounded integration settings from
  `/etc/watch-companion/social-gateway.env`;
- starts one systemd process bound only to `127.0.0.1:8788` and waits up to 15 seconds for its
  health endpoint.

## 3. Add the public Nginx route

Replace the domain placeholder without editing the template:

```bash
sed 's/__SOCIAL_GATEWAY_DOMAIN__/social.example.com/g' \
  deploy/nginx-social-gateway.conf.template \
  >/etc/nginx/sites-available/social-gateway
ln -sfn /etc/nginx/sites-available/social-gateway \
  /etc/nginx/sites-enabled/social-gateway
nginx -t
systemctl reload nginx
```

Only after DNS points to the server and TCP 80/443 are allowed:

```bash
certbot --nginx \
  --domain social.example.com \
  --redirect \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email
```

Verify both paths:

```bash
curl --fail http://127.0.0.1:8788/healthz
curl --fail https://social.example.com/healthz
systemctl is-enabled certbot.timer
certbot renew --dry-run
```

The Apple build setting is the public origin, with no trailing path:

```text
SOCIAL_GATEWAY_BASE_URL=https://social.example.com
```

## Production boundary

Do not call this anonymous, process-local deployment production-ready. Before a
public launch it still needs authenticated account/device ownership, device
attestation and abuse controls, a shared atomic TTL store, bounded durable
idempotency, quotas, observability, and a retention/deletion policy.
