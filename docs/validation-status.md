# Validation Status

This document records reproducible evidence separately from physical-device claims. A Simulator or
mock result never upgrades a hardware-dependent capability to `PASS`.

## 2026-07-24 synchronized pet-transfer acceptance

This acceptance run covers the complete software seam for the no-code A/B touch exchange and the
cross-Watch pet leap.

| Surface | Evidence | Result |
| --- | --- | --- |
| Social-leap art | Penguin and polar-bear 8-frame rows; SHA-bound independent identity reviews; 288 runtime frames; 20 single and 10 duo composites | PASS |
| Live local A/B gateway | A real uvicorn process plus two independent HTTP clients produced one shared event, start time, duration, and opposite source/destination roles | PASS |
| Public HTTPS A/B gateway | Immutable bundle `f1ce4b43…f9344` deployed to `social.bsti.online`; health check plus three consecutive dual-client runs produced one event per run, opposite roles, identical start times, and 1.060–1.101 s projected lead | PASS |
| Social Gateway | 62 total tests, including deployment-permission, clean-runtime-directory, and bounded health-wait regressions; the one-command E2E reruns 18 transfer, privacy, and configuration tests | PASS |
| AppRuntime | 86 tests in 14 suites, including server-time projection on Watch clocks offset by +120 and -75 seconds | PASS |
| Watch A/B UI | Source exit, destination late-entry/landing, same gateway event injection, viewport visibility, and persistent no-replay ledger | PASS |
| One-command E2E | `Scripts/test-social-transfer-e2e`; exactly 2/2 focused UI tests | PASS |
| Release build | Watch Release build with `SOCIAL_GATEWAY_BASE_URL=https://social.bsti.online` | PASS |
| Static policy and formatting | `Scripts/check` plus independent read-only review | PASS |
| Visible 46 mm Simulator inspection | Product touch-exchange screen and the existing Mori/polar-bear identities rendered together after landing | PASS |
| Two physical Watches, live HTTPS Swift clients, UWB, haptics, and mixed-size screen seam | Requires the device runbook | UNVERIFIED |

The final UI result bundle is:

```text
.artifacts/social-transfer-watch-20260723T234220Z-67501.xcresult
```

The deployed integration bundle is:

```text
.artifacts/social-gateway-deploy.siJfYt/watch-social-gateway-deploy.tar.gz
SHA-256 f1ce4b431885379d66c7e22188bb056251da19a7926bc3e5915b171a230f9344
```

The HTTPS endpoint is suitable for the two-device integration run recorded here. It remains an
anonymous, single-process, in-memory rendezvous service, so this row does not upgrade it to a public
launch architecture; authenticated device ownership, abuse controls, and a shared atomic TTL store
remain production-launch work.

The UI suite obtains its shared event ID from the preceding real two-client Gateway run, then
executes the source and destination roles sequentially on one Watch Simulator. This proves the
software protocol-to-presentation seam without a short-lived exchange code. It does not claim that
two physical Watches supplied concurrent Nearby Interaction measurements. The transfer cue is
projected from `server_time` into each Watch's local clock; residual network-response asymmetry can
still create small real-world jitter and belongs in the two-device run.

## 2026-07-24 zero-input touch-exchange implementation check

This check ran against the current uncommitted worktree after removing user-entered pairing codes.

| Surface | Evidence | Result |
| --- | --- | --- |
| Social Gateway | 54 API, concurrency, privacy, generation-isolation, candidate-rotation, orphan-session supersede, TTL, and confirmation tests | PASS |
| AppRuntime | 83 tests, including one-way phone-owned consent sync, replacement candidates, real 409 reconciliation, lost-create recovery, confirm/cancel arbitration, and bounded create retry | PASS |
| AppleAdapters | 33 tests, including Nearby Interaction lifecycle, replacement, invalid-token, and reset events | PASS |
| Watch app compilation | Debug build plus Release build with an injected HTTPS gateway URL | PASS |
| Release gateway guard | Missing gateway URL fails the Release build; all five touch-demo selectors are absent from the Release binary | PASS |
| Watch touch-exchange UI | Seven focused privacy-gate, flow, race, cancellation, and accessibility tests on Apple Watch SE 3 (40 mm), watchOS 26.5 | PASS |
| iPhone privacy controls | Friend-sharing gate and public pet social-state selection on iPhone 17 Pro, iOS 26.5 | PASS |
| Static policy and formatting | `Scripts/check` | PASS |
| Visible 40 mm Simulator inspection | Initial pet surface and touch-exchange assets rendered without launch failure | PASS |
| Two physical Watches, live gateway, and real UWB | Requires the device runbook | UNVERIFIED |

The focused UI tests verify friend sharing is a hard gate before any upload, there is no
pairing-code field, the selected game-only public social state is preserved, the peer card is absent
before the synthetic proximity gate, peer-first still requires local confirmation, delayed
callbacks cannot overwrite cancellation, an unconfirmed remote cancellation is retried before a
new session starts, server-confirmed completion wins a confirm/cancel race, and the consent states
pass an accessibility audit. The Simulator cannot supply real Nearby Interaction measurements, so
these tests use DEBUG-only touch-exchange paths.

The repository-wide `Scripts/test-release-boundaries` build completed, and the touch-exchange
selectors/resources passed its boundary checks. The script then reported the separate current
worktree's `mock1` product-data-source/fixture-identifier overlap; that pre-existing fixture-list
conflict is not counted as touch-exchange validation.

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
