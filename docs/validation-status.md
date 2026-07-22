# Validation Status

This document records reproducible evidence separately from physical-device claims. A Simulator or
mock result never upgrades a hardware-dependent capability to `PASS`.

## 2026-07-23 acceptance run

- Validated code revision: `64bad82`
- Xcode: selected toolchain at `/Applications/Xcode.app/Contents/Developer`
- iPhone destination: iPhone 17 Pro, iOS 26.5 Simulator
- Watch destination: Apple Watch Series 11 (46 mm), watchOS 26.5 Simulator
- Signing: disabled for Simulator builds
- Data: repository fixtures plus an isolated real file-ledger E2E; no personal health data

| Surface | Evidence | Result |
| --- | --- | --- |
| Static policy, formatting, credential scan | `Scripts/check` | PASS |
| Swift domain/runtime/adapters | 25 AppRuntime + 28 AppleAdapters + 57 CompanionCore tests | PASS |
| Narration gateway | 85 Python tests | PASS |
| iPhone app smoke tests | 6 tests | PASS |
| iPhone UI journeys | 3 UI tests | PASS |
| Watch UI journeys | 5 UI tests | PASS |
| Visible Computer Use review | Mac was locked when attempted | UNVERIFIED |
| Physical HealthKit and background delivery | Requires a signed device run | UNVERIFIED |
| Watch-iPhone disconnect/reconnect behavior | Requires a paired device run | UNVERIFIED |
| Notification delivery, Focus behavior, and haptics | Requires a physical Watch | UNVERIFIED |
| Smart alarm extended runtime | Requires the runbook's real-device sequence | UNVERIFIED |
| Nearby Interaction between two Watches | Requires two compatible Watches | UNVERIFIED |

The automated commands were:

```bash
Scripts/bootstrap
Scripts/format
Scripts/check
Scripts/test
Scripts/test-e2e
```

The final UI result bundles are intentionally ignored by Git and were written to:

```text
.artifacts/e2e-phone-20260722T232901Z-75441.xcresult
.artifacts/e2e-watch-20260722T232901Z-75441.xcresult
```

The timestamp in those generated filenames is UTC; the acceptance run occurred on 2026-07-23 in
Asia/Shanghai.

## Covered journeys

The iPhone suite verifies neutral live launch, mock management/wardrobe navigation, and a safe
notification route that does not settle a reward. The Watch suite verifies neutral HealthKit mode,
mock pet interaction, trends and message navigation, a safe optional notification action, and the
offline file-ledger journey:

```text
load local state
→ advance today's main story
→ settle one optional habit reward
→ terminate and relaunch
→ preserve state and reject duplicate settlement
```

The offline journey suppresses Simulator HealthKit refresh and WatchConnectivity startup only when
both `-UITesting` and `--e2e-offline-runtime` are present. It still uses the production event ledger,
reducers, daily gates, and presentation state. Production progression is offline-first: local writes
return before best-effort peer synchronization finishes.

The domain and adapter suites also exercise one thousand parameterized product-event histories plus
one thousand seeded random-draw sequences, one thousand monotonic synchronization-revision
reservations, persisted notification cooldown after runtime recreation, race-safe bounded
connectivity activation, and canonical sleep-stage partitioning for overlapping samples. These tests
verify invariants and failure handling; they do not substitute for the device gates below.

## Remaining device gate

Follow [device-runbook.md](device-runbook.md) before describing any hardware-dependent item as
shipped or verified. In particular, do not claim real-time sleep staging, guaranteed notification
delivery, UWB friendship exchange, or reliable background execution based on Simulator evidence.
