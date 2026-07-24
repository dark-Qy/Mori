#!/usr/bin/env bash

set -euo pipefail

base_url=${NARRATION_SMOKE_BASE_URL:-https://social.bsti.online}
if [[ -z ${NARRATION_SMOKE_TOKEN:-} ]]; then
  echo "Set NARRATION_SMOKE_TOKEN to the gateway token; do not pass it on the command line." >&2
  exit 1
fi

health_payload=$(curl \
  --fail \
  --silent \
  --show-error \
  --max-time 5 \
  "$base_url/ai/healthz")

response_payload=$(curl \
  --fail \
  --silent \
  --show-error \
  --max-time 8 \
  --header "Authorization: Bearer $NARRATION_SMOKE_TOKEN" \
  --header "Content-Type: application/json" \
  --data-binary '{
    "request_id": "deployment-smoke-001",
    "source_hash": "deployment.smoke:20260725",
    "locale": "zh-CN",
    "activities": [
      {"kind": "tennis", "duration_minutes": 45},
      {"kind": "swimming", "duration_minutes": 60}
    ],
    "total_steps": 42350,
    "active_minutes": 210,
    "average_sleep_minutes": 435,
    "personality": {
      "voice": "warm",
      "pace": "balanced",
      "themes": ["racket_sports", "water_sports"]
    }
  }' \
  "$base_url/ai/v1/weekly-memories/polish")

HEALTH_PAYLOAD=$health_payload RESPONSE_PAYLOAD=$response_payload python3 - <<'PY'
import json
import os

health = json.loads(os.environ["HEALTH_PAYLOAD"])
response = json.loads(os.environ["RESPONSE_PAYLOAD"])

if health != {"status": "ok", "upstream_configured": True}:
    raise SystemExit(f"unexpected health response: {health!r}")
if response.get("source") != "upstream":
    raise SystemExit(
        "smoke test reached only deterministic fallback: "
        f"{response.get('fallback_reason', 'unknown')}"
    )
if response.get("safe") is not True:
    raise SystemExit("smoke response was not marked safe")
if response.get("source_hash") != "deployment.smoke:20260725":
    raise SystemExit("smoke response did not preserve source_hash")
if not response.get("title") or not response.get("body"):
    raise SystemExit("smoke response has empty copy")

print(
    json.dumps(
        {
            "health": "ok",
            "source": response["source"],
            "safe": response["safe"],
            "source_hash": response["source_hash"],
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )
)
PY
