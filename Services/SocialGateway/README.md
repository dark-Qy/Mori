# Social Gateway

`SocialGateway` is the ephemeral server-side rendezvous layer for the Watch
Companion “touch to exchange” MVP. Two watches enter an ephemeral global
discovery pool, exchange temporary Nearby Interaction discovery
tokens with an automatically selected candidate, prove that both clients
reached the product's proximity threshold within a short time window, preview
an allowlisted game-only pet card, and confirm the encounter independently.

It is intentionally separate from `NarrationGateway`.

## MVP boundary

- `participant_id` is an opaque, URL-safe, high-entropy identifier generated
  and persisted by each client installation. For this anonymous MVP it is a
  **bearer credential**: a caller that knows it can replace that participant's
  unfinished join. Clients must generate at least 128 random bits, keep the
  value private, and send it only over TLS. It is **not** an Apple identity,
  account, attestation, or production authentication mechanism.
- `join_request_id` is a client-generated, URL-safe idempotency key unique to
  one join attempt. Replaying the same participant/request/payload returns the
  same join response and nonce. Reusing the key with any different token or
  card returns `idempotency_conflict`. Sanitized terminal idempotency records
  remain for the process lifetime so a delayed old request cannot become a new
  join after its session tombstone is pruned.
- Each join returns a random per-session `nonce`. Every later operation requires
  the exact `session_id`, `participant_id`, and nonce. Invalid combinations get
  the same generic 404.
- A global in-memory discovery pool automatically selects temporary two-party
  candidates. A participant cannot have two active sessions and can never be
  paired with itself. A new `join_request_id` for the same participant
  atomically supersedes its unfinished session. If it was matched, the old
  peer and encounter are cancelled too. A delayed replay of the old join only
  returns its sanitized `cancelled` result and cannot replace the new session.
  Completed `confirmed` encounters are immutable and are never superseded.
- NI discovery tokens are available to the matched peer immediately because
  they are required to begin ranging. Pet cards remain unavailable until both
  clients report `proximity-ready`.
- A candidate that does not verify within 12 seconds by default is released.
  Both participants keep the same session, nonce, local NI token, and card; their
  status returns to `waiting`, encounter fields and the old peer token disappear,
  and the server automatically searches again. Recent failed peers are avoided
  during one candidate cooldown so a larger pool rotates candidates instead of
  immediately recreating the same pair.
- Each proximity report is timestamped. The encounter locks
  `proximity_verified` only if the two latest reports are no more than five
  seconds apart by default. A late report invalidates the older report, and a
  locked verification is not reopened.
- Calling `peer-card` records `preview_released` for that participant.
  Confirmation is rejected until that same participant has retrieved the peer
  card. Confirmation is idempotent, and the encounter becomes `confirmed` only
  when both participants confirm.
- Cancellation propagates to both participants. Waiting sessions and encounters
  expire automatically, sensitive token/card data is erased on cancellation or
  expiration, and short-lived tombstones are then pruned.
- A FastAPI lifespan task runs TTL cleanup periodically, so sensitive data is
  erased even when no client sends another request. Request-time cleanup remains
  as an additional guard.
- This process-local store is suitable for an integration spike and tests, not a
  multi-instance production deployment. Production needs authenticated
  identities, attestation/abuse controls, TLS, a shared atomic store, quotas,
  observability, and a defined retention/deletion policy.

The server never determines physical contact. Clients own the Nearby
Interaction distance/sampling rule and report only the boolean readiness event.

## State machine

```text
waiting
  -> matched
  -> proximity_ready  (both reports landed inside the allowed time window)
  -> confirmed        (both clients previewed and confirmed)

matched -> waiting    (candidate timeout; same session automatically requeued)
waiting|matched|proximity_ready -> cancelled
waiting|matched|proximity_ready -> expired
```

The API returns timezone-aware `expires_at` timestamps. Completed, cancelled,
and expired records are retained only long enough for polling clients to observe
their terminal result.

## Public API

All mutation-like calls use `POST` with `Content-Type: application/json`.
Responses, including errors and OpenAPI, carry `Cache-Control: no-store`.
Unknown fields are rejected.

### 1. Join or create a wait

`POST /v1/sessions`

```json
{
  "participant_id": "install_R4nd0mOpaqueValue_123",
  "join_request_id": "join_K9m2UniqueAttempt_456",
  "discovery_token": "YmluYXJ5LU5JLXRva2Vu",
  "public_card": {
    "schema_version": "public_pet_card_v1",
    "pet_name": "Mochi",
    "character_id": "capoo-blue",
    "outfit_id": "raincoat-yellow",
    "background_id": "forest-dawn",
    "social_state": "greeting"
  }
}
```

Returns HTTP 201:

```json
{
  "session_id": "c72e97b6b4a6c41512c98df081e257f2",
  "nonce": "per-session-secret-returned-only-by-join",
  "status": "waiting",
  "expires_at": "2026-07-23T08:01:00Z",
  "encounter_id": null,
  "encounter_nonce": null,
  "peer_discovery_token": null,
  "self_proximity_ready": false,
  "peer_proximity_ready": false,
  "proximity_verified": false,
  "proximity_verified_at": null,
  "self_preview_released": false,
  "peer_preview_released": false,
  "self_confirmed": false,
  "peer_confirmed": false
}
```

The second participant normally receives `status: "matched"`, the shared random
`encounter_id`/`encounter_nonce`, and the first participant's
`peer_discovery_token`. The first participant obtains the same encounter data
and the second token by polling status.

Only the temporary NI discovery token crosses the boundary at `matched`.
`public_card` is not included in join or status and remains gated behind
server-locked proximity verification.

An idempotent replay deliberately returns the stored join response. For example,
the first participant may receive the same original `waiting` response after a
match has occurred; use the status endpoint to read current encounter state.
When a candidate times out, or a session is cancelled or expires, the stored
response is replaced by a sanitized `waiting` or terminal snapshot so it cannot
retain an obsolete peer NI token.

Starting a fresh local `NISession` uses a fresh `join_request_id`. The gateway
atomically cancels/tombstones any unfinished session for that `participant_id`
before creating the replacement. A response-loss retry must reuse the original
join key; if the client intentionally replaces its NI session, it must use a new
key. If the old session had a candidate, both sides of that old encounter are
cancelled. An old key remains bound to the old cancelled result even after the
session record itself is pruned.

### 2. Poll status and peer NI token

`POST /v1/sessions/{session_id}/status`

Clients poll this route while discovery/ranging is active. A timed-out candidate
returns to `status: "waiting"` with the same `session_id` and nonce, while
`encounter_id`, `encounter_nonce`, and `peer_discovery_token` become null. When
the pool selects another candidate, the same route returns `matched` with a new
encounter and peer token. Clients should ignore measurements from the old
candidate on the `matched -> waiting` transition while preserving the local NI
session whose discovery token remains registered with the gateway. Running a
new peer configuration replaces the old candidate when another token appears.

Status uses the session credential:

```json
{
  "participant_id": "install_R4nd0mOpaqueValue_123",
  "nonce": "the-random-nonce-returned-by-join"
}
```

Every candidate-specific action is bound to the generation returned by the
latest status response:

```json
{
  "participant_id": "install_R4nd0mOpaqueValue_123",
  "nonce": "the-random-nonce-returned-by-join",
  "encounter_id": "the-current-32-character-encounter-id",
  "encounter_nonce": "the-current-random-encounter-nonce"
}
```

The server validates all four values atomically under the state lock. A delayed
ready, preview, confirm, or candidate cancel from an older match returns 409
`stale_encounter` and cannot mutate the replacement match.

### 3. Report that the local NI rule is ready

`POST /v1/sessions/{session_id}/proximity-ready`

The server records the report time. When the peer report is within
`SOCIAL_PROXIMITY_WINDOW_SECONDS`—five seconds by default—the encounter is
irreversibly marked `proximity_verified: true` and returns
`status: "proximity_ready"` plus `proximity_verified_at`. If the reports are too
far apart, the older report is cleared; both clients must overlap again.

### 4. Read the peer's game-only card

`POST /v1/sessions/{session_id}/peer-card`

Returns 409 `proximity_not_ready` until **both** participants have reported
ready. It then returns:

```json
{
  "encounter_id": "shared-encounter-id",
  "encounter_nonce": "the-current-random-encounter-nonce",
  "public_card": {
    "schema_version": "public_pet_card_v1",
    "pet_name": "Mochi",
    "character_id": "capoo-blue",
    "outfit_id": "raincoat-yellow",
    "background_id": "forest-dawn",
    "social_state": "greeting"
  }
}
```

`PublicPetCardV1` accepts only the fields above. There is no health, sleep,
vitality, inferred mood/theme, location, account identifier, or arbitrary
message field. `social_state` is one of `greeting`, `walk`, or `quiet_company`.
Each successful call also sets `self_preview_released: true` in later status
responses. Clients must compare both returned encounter fields with the current
status generation before presenting the card; this discards an old HTTP response
that completed after candidate rotation.

### 5. Confirm independently

`POST /v1/sessions/{session_id}/confirm`

This returns 409 `preview_required` unless that participant has already called
`peer-card`. It is then idempotent. The first confirmation leaves the encounter
at `proximity_ready`; after the peer previews and confirms, both clients observe
`confirmed`. Every session snapshot also includes `server_time`. A confirmed
snapshot adds one presentation-only transfer cue:

```json
{
  "server_time": "2026-07-24T08:00:00Z",
  "status": "confirmed",
  "transfer_role": "source",
  "transfer_animation": {
    "schema_version": "pet_transfer_animation_v1",
    "event_id": "the-shared-encounter-id",
    "role": "source",
    "starts_at": "2026-07-24T08:00:01.250Z",
    "duration_ms": 900
  }
}
```

Both clients receive the same `event_id`, `starts_at`, and duration. The
participant that entered the waiting pool first is always `source`; the other
is `destination`, independent of confirmation order. `transfer_role` is also
present as soon as a match is formed so the clients can show the source on the
left and destination on the right before the animation begins. Repeated confirm/status
calls return the same cue. This cue affects presentation only and cannot create
or alter an encounter. The 1.25-second default lead lets both Watches receive
the confirmed snapshot before the animation begins.

The existing `encounter_nonce` is a correlation/synchronization value, not an
account identity credential; together with `encounter_id`, it is the required
unreplayable generation credential for candidate-scoped mutations.

### 6. Cancel

`POST /v1/sessions/{session_id}/cancel`

Cancelling a `waiting` session uses the session credential. Once a candidate is
`matched`, cancel must include the current encounter generation shown above.
A bare matched cancel returns 409 `encounter_generation_required`; this prevents
a delayed search-screen request from cancelling a newer candidate.

`POST /v1/maintenance/cleanup` is an undocumented, idempotent local maintenance
hook. It accepts `{}` and can only expire or prune entries whose TTL has already
elapsed. Normal API operations also run cleanup before accessing state.

## Privacy and operational constraints

- Request bodies are capped before JSON parsing. A decoded NI token is capped at
  2 KiB and must use canonical base64.
- Idempotency keys, identifiers, enum values, asset IDs, strings, and object
  fields have explicit bounds. Validation errors do not echo Pydantic's rejected
  input.
- Structured audit events contain only random session/encounter IDs, action, and
  outcome. The audit type cannot accept participant IDs, nonces, NI tokens, or
  cards. The local entrypoint disables Uvicorn access logging.
- The default process binds only to `127.0.0.1:8788`.
- Do not expose this global anonymous discovery pool directly to the internet.
  Possession of a `participant_id` is sufficient to supersede its unfinished
  session, so it intentionally has no user account or trusted identity
  boundary. A production deployment must verify authenticated account/device
  ownership before allowing supersede, and add TLS, attestation/abuse controls,
  request quotas, candidate selection policy, bounded durable idempotency
  retention, and a shared transactional/TTL data store.

## Local setup

Python 3.9 or newer is supported.

```bash
cd Services/SocialGateway
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e '.[test]'
python -m social_gateway
```

OpenAPI is available at `GET /openapi.json`; interactive docs are disabled.

## Test and quality checks

```bash
cd Services/SocialGateway
python3 -m pytest
python3 -m compileall -q src tests
ruff check .
ruff format --check .
```

The suite covers concurrent global-pool pairing, self-pair prevention,
multi-candidate rotation, same-session timeout/retry, join
idempotency/conflicts, stale-generation rejection, delayed-request isolation,
temporary NI token exchange, card privacy gates,
timestamp-window verification, per-party preview gating, two-party confirmation
and retries, cancellation, request-free lifespan cleanup, expiration/purge,
credential binding, capacity, strict schemas, byte/token limits, no-store
headers, audit redaction, and configuration bounds.

## Configuration

| Variable | Default | Allowed |
| --- | ---: | ---: |
| `SOCIAL_WAITING_TTL_SECONDS` | 60 | 15–300 |
| `SOCIAL_ENCOUNTER_TTL_SECONDS` | 180 | 30–600 |
| `SOCIAL_CANDIDATE_TTL_SECONDS` | 12 | 5–60 |
| `SOCIAL_TOMBSTONE_TTL_SECONDS` | 60 | 5–300 |
| `SOCIAL_PROXIMITY_WINDOW_SECONDS` | 5.0 | 1.0–15.0 |
| `SOCIAL_TRANSFER_ANIMATION_LEAD_SECONDS` | 1.25 | 0.75–3.0 |
| `SOCIAL_TRANSFER_ANIMATION_DURATION_MS` | 900 | 500–2000 |
| `SOCIAL_CLEANUP_INTERVAL_SECONDS` | 1.0 | 0.01–60.0 |
| `SOCIAL_MAX_REQUEST_BYTES` | 16384 | 4096–65536 |
| `SOCIAL_MAX_ACTIVE_PARTICIPANTS` | 10000 | 2–100000 |
