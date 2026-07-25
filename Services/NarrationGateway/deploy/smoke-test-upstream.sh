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

chat_payload=$(curl \
  --fail \
  --silent \
  --show-error \
  --max-time 8 \
  --header "Authorization: Bearer $NARRATION_SMOKE_TOKEN" \
  --header "Content-Type: application/json" \
  --data-binary '{
    "request_id": "deployment-speech-smoke-001",
    "locale": "zh-CN",
    "messages": [
      {"role": "user", "content": "请用一句很短的话确认语音链路。"}
    ],
    "personality": {
      "voice": "warm",
      "pace": "gentle",
      "themes": ["exploration"],
      "is_personalized": false
    }
  }' \
  "$base_url/ai/v1/chat/reply")

HEALTH_PAYLOAD=$health_payload RESPONSE_PAYLOAD=$response_payload CHAT_PAYLOAD=$chat_payload python3 - <<'PY'
import json
import os

health = json.loads(os.environ["HEALTH_PAYLOAD"])
response = json.loads(os.environ["RESPONSE_PAYLOAD"])
chat = json.loads(os.environ["CHAT_PAYLOAD"])

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
if chat.get("source") != "upstream":
    raise SystemExit(
        "chat smoke reached only deterministic fallback: "
        f"{chat.get('fallback_reason', 'unknown')}"
    )
if chat.get("request_id") != "deployment-speech-smoke-001":
    raise SystemExit("chat smoke did not preserve request_id")
if not chat.get("reply"):
    raise SystemExit("chat smoke response has empty reply")

print(
    json.dumps(
        {
            "health": "ok",
            "weekly_source": response["source"],
            "safe": response["safe"],
            "source_hash": response["source_hash"],
            "chat_source": chat["source"],
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )
)

PY

speech_dir=$(mktemp -d)
trap 'rm -rf "$speech_dir"' EXIT
speech_status=$(curl \
  --silent \
  --show-error \
  --max-time 12 \
  --header "Authorization: Bearer $NARRATION_SMOKE_TOKEN" \
  --header "Content-Type: application/json" \
  --data-binary '{"request_id":"deployment-speech-smoke-001"}' \
  --dump-header "$speech_dir/headers" \
  --output "$speech_dir/body" \
  --write-out '%{http_code}' \
  "$base_url/ai/v1/audio/speech")

if [[ $speech_status != 200 ]]; then
  echo "speech smoke returned HTTP $speech_status" >&2
  exit 1
fi

SPEECH_HEADERS_PATH=$speech_dir/headers SPEECH_BODY_PATH=$speech_dir/body python3 - <<'PY'
import json
import os
from pathlib import Path

headers = Path(os.environ["SPEECH_HEADERS_PATH"]).read_text(
    encoding="utf-8",
    errors="replace",
).lower()
audio = Path(os.environ["SPEECH_BODY_PATH"]).read_bytes()

if "content-type: audio/mpeg" not in headers:
    raise SystemExit("speech smoke did not return audio/mpeg")
if not 0 < len(audio) <= 10_485_760:
    raise SystemExit(f"speech smoke returned an invalid audio size: {len(audio)}")

print(
    json.dumps(
        {
            "speech": "audio/mpeg",
            "speech_bytes": len(audio),
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )
)
PY
