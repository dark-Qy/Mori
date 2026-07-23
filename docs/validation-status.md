# Validation Status

This document records reproducible evidence separately from physical-device claims. A Simulator or
mock result never upgrades a hardware-dependent capability to `PASS`.

## 2026-07-23 acceptance run

- Validated production UI revision: `0adfc11`
- Validated test-harness revision: `f657698`
- Xcode: 26.6 (`17F113`) at `/Applications/Xcode.app/Contents/Developer`
- iPhone destination: iPhone 17 Pro, iOS 26.5 Simulator
- Final Watch destination: Apple Watch SE 3 (40 mm), watchOS 26.5 Simulator
- Signing: disabled for Simulator builds
- Data: repository fixtures plus isolated real file-ledger E2E; no personal health data

| Surface | Evidence | Result |
| --- | --- | --- |
| Static policy, formatting, credential scan | `Scripts/check` | PASS |
| Release fixture and launch-hook boundary | `Scripts/test-release-boundaries` | PASS |
| AppRuntime | 39 tests in 10 suites | PASS |
| AppleAdapters | 28 tests in 5 suites | PASS |
| CompanionCore | 62 tests in 11 suites, including 1,000 deterministic product timelines | PASS |
| Narration Gateway | 85 tests | PASS |
| iPhone app smoke | 7 tests | PASS |
| iPhone UI journeys | 9 tests on iPhone 17 Pro | PASS |
| Watch UI journeys | 11 tests on Apple Watch SE 3 (40 mm) | PASS |
| Accessibility matrix | light iPhone; dark/high-contrast/AXXXL iPhone; 40 mm Watch | PASS |
| Visible Computer Use review | Watch onboarding/no-data/explanation/story; iPhone management and adaptive appearance | PASS |
| Physical HealthKit and background delivery | Requires a signed device run | UNVERIFIED |
| Watch-iPhone disconnect/reconnect behavior | Requires a paired-device run | UNVERIFIED |
| Notification delivery, Focus behavior, and haptics | Requires a physical Watch | UNVERIFIED |
| Smart alarm extended runtime | Requires the runbook's real-device sequence | UNVERIFIED |
| Nearby Interaction between two Watches | Requires two compatible Watches | UNVERIFIED |

The automated commands were:

```bash
Scripts/bootstrap
Scripts/format
Scripts/test-release-boundaries
Scripts/check
Scripts/test
Scripts/test-e2e
Scripts/test-accessibility
```

The final exact-revision UI result bundles are intentionally ignored by Git and were written to:

```text
.artifacts/e2e-phone-20260723T050049Z-46825.xcresult
.artifacts/e2e-watch-40mm-final-20260723T060745Z-69195.xcresult
.artifacts/accessibility-phone-light-standard-20260723T045141Z-41861.xcresult
.artifacts/accessibility-phone-dark-high-axxxl-20260723T045141Z-41861.xcresult
.artifacts/accessibility-watch-40mm-20260723T045141Z-41861.xcresult
.artifacts/accessibility-watch-40mm-final-tap-20260723T063449Z-77501.xcresult
```

The accessibility filenames use UTC timestamps; the acceptance run occurred on 2026-07-23 in
Asia/Shanghai. The phone suite contains 9 passing tests. The final 40 mm Watch suite contains 11
passing tests; after hardening its navigation tap helper, the affected 40 mm accessibility test was
run again and passed independently. Each accessibility matrix result contains exactly one executed,
passing test; the script rejects empty or partially failing result bundles.

## Covered journeys

The iPhone suite verifies neutral live launch, explicit onboarding, partial-health semantics,
fail-closed unknown Mock selection, management navigation, locked versus unlocked wardrobe state,
offline wardrobe persistence/reset, privacy scope activation, safe notification routing, and the
management-surface accessibility audit.

The Watch suite verifies neutral HealthKit mode, onboarding and pet introduction, partial-health
semantics, source explanation, AI offline/malformed equivalence, soccer eligibility without forced
random-story unlock, trend and message navigation, fail-closed invalid Mock selection, safe
notification navigation, primary-surface accessibility, and the offline file-ledger journey:

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

## Visible review

Computer Use operated the real Simulator UI instead of relying on screenshots alone:

- on a 46 mm Watch, it entered onboarding, verified the no-auto-permission statement, opened the
  neutral no-health state, inspected the source explanation, returned, and advanced the daily story;
- on iPhone 17 Pro with the labeled `health_partial` fixture, it inspected semantic metric values,
  previewed a locked wardrobe item, opened privacy controls, enabled the local-only sharing preset,
  and selected `有限健康摘要` while the UI continued to exclude raw sleep stages, heart-rate values,
  and source records;
- after the adaptive-palette fix, it inspected the live iPhone dashboard in standard light mode and
  dark, increased-contrast, accessibility-XXXL mode. The hero card retained a dark background with
  readable white text, and the bottom tab bar retained a visually hard boundary. It did not trigger
  HealthKit authorization.

No external service was connected and no personal or synthetic health value was transmitted.

## Remaining device gate

Follow [device-runbook.md](device-runbook.md) before describing any hardware-dependent item as
shipped or verified. In particular, do not claim real-time sleep staging, guaranteed notification
delivery, UWB friendship exchange, reliable background execution, haptic behavior, or smart-alarm
wake behavior based on Simulator evidence.
