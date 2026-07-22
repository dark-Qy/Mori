# Mock Data

## Purpose

Mocks make deterministic development possible when HealthKit history, physical hardware, APNs, AI, or proximity is unavailable. A mock is a product-development mode, not evidence that the real capability works.

## Non-negotiable labeling

- Every debug screen using synthetic data displays **Demo Data** or **模拟数据** persistently.
- Screenshots and recordings retain that label.
- Debug diagnostics identify the fixture and random seed.
- Release builds do not expose fixture selection or silently substitute synthetic health data.
- If production data is unavailable, production UI uses a neutral no-data state rather than a fake successful state.

## Fixture format

Fixtures use versioned JSON stored separately from user data:

```json
{
  "fixtureVersion": 1,
  "id": "health_normal",
  "anchorTime": "2026-01-15T08:00:00+08:00",
  "timeZone": "Asia/Shanghai",
  "randomSeed": 42,
  "capabilities": {
    "healthKit": "mock",
    "notifications": "mock",
    "ai": "offline"
  },
  "events": []
}
```

Dates are interpreted relative to `anchorTime` where possible. Fixtures never contain copied health exports, real names, contact details, provider keys, device identifiers, or personal conversations.

## Required scenarios

| ID | Purpose | Key expectation |
|---|---|---|
| `fresh_install` | Empty ledger and first launch | deterministic onboarding |
| `permission_not_requested` | No HealthKit request yet | neutral explanation, no negative inference |
| `health_no_data` | Permission path with no samples | pet remains playable |
| `health_partial` | Some requested types unavailable | use only known context and disclose limits |
| `health_normal` | Representative recent trends | primary single-user loop |
| `sleep_stale` | Old sleep sample | freshness rule rejects health claim |
| `activity_high` | Activity near soft cap | diminishing reward behavior |
| `soccer_workout` | Recorded soccer workout | eligibility without guaranteed random trigger |
| `notification_denied` | Notification permission denied | in-app path, no repeated prompt loop |
| `ai_offline` | Narration unavailable | deterministic local template |
| `ai_malformed` | Invalid narration schema | validation and local fallback |
| `sync_unreachable` | Watch/iPhone unavailable | queue and idempotent recovery |
| `pet_new` | Initial pet state | first chapter behavior |
| `outfit_locked` | Locked cosmetic | clear non-punitive state |
| `outfit_unlocked` | Available cosmetic | preview/equip/reset flow |

Add explicit scenarios for each bug that depends on time, permission, ordering, or randomness.

## Fault injection

Mocks support controlled:

- latency and timeout;
- duplicate, delayed, reordered, and missing events;
- corrupted persistence and unsupported schema;
- revoked or partial permissions;
- clock and time-zone changes;
- provider 401, 429, 5xx, invalid JSON, unsafe text, and oversize text;
- disconnected Watch/iPhone and reconciliation;
- background callback never arriving.

The rule result must be inspectable through a redacted `DecisionTrace`.

## Determinism

Fixture, application version, rule version, clock, and random seed fully identify an expected run. Tests may assert a specific branch only when the seed is fixed. Production randomness never selects an option that did not pass rule eligibility.

## Adding a fixture

1. State the behavior and invariant it proves.
2. Use entirely synthetic values near meaningful boundaries.
3. Add schema validation and a test that loads the fixture.
4. Add an E2E assertion or document why it is adapter-only.
5. Confirm the Demo Data label remains visible.
6. Record the fixture in this document.
