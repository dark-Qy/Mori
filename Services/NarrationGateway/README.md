# Narration Gateway

This service turns bounded health, pet, rule, and story context into one short
virtual-pet narration. It is a server-side boundary: Apple clients must never
receive the upstream API key or call the model provider directly.

The service is intentionally useful without a provider. A missing key and every
expected upstream failure return deterministic local narration with
`source: "fallback"` and a machine-readable `fallback_reason`.

## Architecture

```text
POST /v1/narrations
  -> bearer authentication and per-process rate limit
  -> byte and content-type boundary
  -> strict Pydantic request schema
  -> provider-neutral prompt builder
  -> injected OpenAI-compatible transport
  -> bounded /v1/chat/completions response
  -> strict tone decision schema
  -> server-owned, reviewed narration template
  -> upstream narration OR deterministic local fallback
```

The transport is injected into `NarrationService`, so tests and the free
Personal Team experience need no network or APNs. Production uses
`HttpxChatCompletionTransport`; tests use scripted transports.

## Privacy and safety boundaries

- Request fields and collection lengths are allowlisted and capped. Arbitrary
  top-level prompts and unknown fields are rejected. Free text inside an
  allowlisted context field cannot become user-facing output because the model
  may return only `calm`, `warm`, or `playful`.
- The schema can carry last-night sleep stages, up to 14 relative daily
  summaries, a 30-day baseline, recent heart/activity context, rule hits, and
  story state. Daily history uses `day_offset` instead of calendar dates to
  avoid sending an unnecessary identifier.
- Request bodies are limited before JSON parsing. Upstream bodies are streamed
  and stopped at their byte limit.
- Upstream calls have a hard timeout of at most five seconds.
- Provider output must be one strict JSON tone decision. The service renders
  final narration from reviewed local templates and applies the configured
  character budget to both upstream-selected and fallback paths. The model can
  neither return a diagnosis/directive nor smuggle context text into the copy.
- Audit events contain only request ID, outcome code, and upstream status. They
  cannot accept health text, prompts, narration, headers, credentials, or raw
  exceptions. Uvicorn access logging is disabled by the local entrypoint.
- Validation errors never echo Pydantic input snapshots.
- `POST /v1/narrations` always requires a separately configured gateway bearer
  token and is protected by a bounded per-process request limit. Missing auth
  configuration fails closed. The default server also binds only to
  `127.0.0.1`. Production still requires short-lived user/session credentials,
  a shared distributed quota, TLS, and a private deployment boundary; the
  single local token is a Phase 2 development foundation, not multi-user auth.
- Narration responses use `Cache-Control: no-store`.

This is a wellness narration feature, not a medical device. The calling product
must obtain appropriate user consent before sending health data and must define
retention/deletion and provider data-processing policies. The gateway itself
does not persist request bodies.

## Local setup

Python 3.9 or newer is supported.

```bash
cd Services/NarrationGateway
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e '.[test]'
cp .env.example .env
```

Put the development credential only in the ignored `.env`. This service reads
configuration from process environment and does not parse secret files itself:

```bash
set -a
source .env
set +a
python -m narration_gateway
```

Generate a distinct local `NARRATION_GATEWAY_ACCESS_TOKEN` with at least 24
visible characters. Clients send it as `Authorization: Bearer <token>`. Never
reuse the upstream provider key for this purpose.

Do not reuse a credential that has appeared in chat, logs, or source control;
rotate it before live testing.

## API

`POST /v1/narrations` requires the configured bearer token and
`Content-Type: application/json`. Its OpenAPI
schema is available at `/openapi.json`; interactive documentation is disabled.
Successful and fallback narrations both return HTTP 200 so a pet interaction
does not disappear when the model is unavailable:

```json
{
  "request_id": "request-001",
  "narration": "我注意到你的节奏有一点变化。先照顾好当下，我们晚些再一起回顾。",
  "source": "fallback",
  "fallback_reason": "upstream_timeout",
  "safe": true
}
```

Boundary errors are 401 for missing/invalid auth, 413 for too many bytes, 415
for non-JSON content, 422 for schema mismatches, 429 for local quota exhaustion,
and 503 when gateway auth is not configured. These errors contain no input echo.
`GET /healthz` reports only readiness and whether upstream configuration is
present.

The upstream must implement `POST /v1/chat/completions` and accept the standard
chat-completion fields emitted by `prompting.py`. Its response is accepted only
when it selects an allowed tone with the exact declared schema; direct narration,
unexpected provider fields, and prompt-injection output fail closed to local copy.

## Tests

```bash
cd Services/NarrationGateway
python3 -m pytest
python3 -m compileall -q src tests
ruff check .
ruff format --check .
```

The suite covers the success path, strict public boundary, injected transport,
credential redaction surface, 401, 429, 5xx, timeout, network/malformed/unsafe
responses, provider schema drift, direct-medical-copy rejection,
response/request oversize behavior, authentication, rate limiting, and a slow
stream that attempts to exceed the wall-clock deadline.

## Environment variables

| Variable | Default | Constraint |
| --- | --- | --- |
| `NARRATION_UPSTREAM_BASE_URL` | `https://api-gateway.openagents.org` | HTTPS origin, no embedded credentials |
| `NARRATION_UPSTREAM_MODEL` | `deepseek-4-flash` | 1–128 characters |
| `NARRATION_UPSTREAM_API_KEY` | unset | Read only from process environment |
| `NARRATION_GATEWAY_ACCESS_TOKEN` | unset | Required for narration requests; 24–4096 visible characters |
| `NARRATION_UPSTREAM_TIMEOUT_SECONDS` | `2.5` | 0.25–5.0 seconds |
| `NARRATION_MAX_REQUEST_BYTES` | `32768` | 4096–65536 bytes |
| `NARRATION_MAX_UPSTREAM_RESPONSE_BYTES` | `16384` | 1024–65536 bytes |
| `NARRATION_MAX_CHARACTERS` | `180` | 40–300 characters |
| `NARRATION_RATE_LIMIT_REQUESTS` | `30` | 1–600 requests per process/window |
| `NARRATION_RATE_LIMIT_WINDOW_SECONDS` | `60` | 1–3600 seconds |

## Known integration risks

- OpenAI-compatible providers sometimes add response fields. This gateway
  deliberately treats undeclared fields as malformed until the schema and tests
  are reviewed and updated.
- Final user-facing templates still require human product and localization
  review. Model-selected tone is not a medical interpretation.
- Retries are intentionally absent: they can amplify cost, latency, and duplicate
  narration. The caller can request a new narration under its own idempotency
  policy.
