# Mori Rebuild Status

## Current Goal

| Field | Value |
| --- | --- |
| Branch | `codex/mori-product-rebuild` |
| Base revision | `51b9a58` |
| Current revision | G0 contract checkpoint (this commit) |
| Active goal | G1 — Authoritative Product Domain |
| Goal state | Contract ready |
| Contract | G0 reviewed and committed; G1 implementation next |
| Simulator validation | Historical baseline recorded; rebuilt UI not started |
| Physical-device validation | UNVERIFIED |

## Goal Ledger

| Goal | State | Revision | Evidence | Blocker / next action |
| --- | --- | --- | --- | --- |
| G0 Product and baseline contract | Committed | G0 contract checkpoint (this commit) | Product/design authority, ADR 0001–0006, route/state and deletion contracts, test matrix, capability audit, approved Image2 references, Release-boundary fix, fresh package/app/E2E baseline, four-round independent review | Complete; physical capability remains independently UNVERIFIED |
| G1 Authoritative product domain | Contract ready | — | Types, invariants, migrations, properties, and negative tests assigned | Implement profile-scoped records and pure reducers |
| G2 Evidence and profile runtime | Pending | — | Test cases assigned | Depends on G1 |
| G3 Sync, reminder, daily memory | Pending | — | Test cases assigned | Depends on G2 |
| G4 Mori motion system | Pending | — | Existing asset baseline and approved semantic catalog contract | Depends on G0 |
| G5 Watch experience | Pending | — | Route/state and UI journeys assigned | Depends on G2, G3, G4 |
| G6 iPhone experience | Pending | — | Route/state and UI journeys assigned | Depends on G2, G3, G4, G7 |
| G7 Mori conversation | Pending | — | Authority and privacy ADR plus adversarial cases assigned | Depends on G2, G3 |
| G8 End-to-end product loops | Pending | — | Cross-device cases assigned | Depends on G5, G6, G7 |
| G9 Release and open-source quality | Pending | — | Release and open-source gates assigned | Depends on G8 |

## Baseline Evidence

### PASS

| Check | Revision / tree | Result |
| --- | --- | --- |
| `Scripts/bootstrap` | `51b9a58` plus initial planning docs | Local Swift and Python tooling resolved |
| `Scripts/check` | `e4265fe` plus G0 contract tree | PASS |
| `Scripts/test-release-boundaries` | `e4265fe` | PASS; Release contains no fixture resources, test launch selectors, or Mock fixture identifiers |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/AppRuntime -c release` | `e4265fe` | PASS, 83 tests |
| `Scripts/test` | `e4265fe` | PASS; AppRuntime Debug 85 tests, remaining package suites PASS, iPhone AppSmokeTests 7 tests |
| `Scripts/validate-visual-assets --allow-pending` | `e4265fe` plus G0 contract tree | PASS: 10 scenes, 2 characters, 256 runtime frames, 20 solo composites, 10 duo composites |
| iPhone default Debug profile | `e4265fe` E2E | PASS; launches with Mock 1 and remembers a selected Mock |
| Watch default Debug profile | `e4265fe` Watch E2E | PASS; launches with Mock 1 and remembers a selected Mock |

### EXACT BASELINE FAILURES

These tests describe the pre-rebuild UI and are not accepted product behavior.
They remain exact evidence until their owning G5/G6 replacements pass.

#### iPhone UI

- Command: `Scripts/test-e2e`
- Revision: `e4265fe`
- Result bundle:
  `.artifacts/e2e-phone-20260723T222615Z-8596.xcresult`
- Result: 10 total, 5 passed, 5 failed.

Failed tests:

1. `PhoneAppUITests.testAccessibilityAuditAcrossManagementSurfaces()` —
   accessibility audit reported `Contrast failed`.
2. `PhoneAppUITests.testCharacterAndSharedBackgroundSelectionUpdateThePreview()` —
   expected `背景已更新；Mock 模拟手表可达`.
3. `PhoneAppUITests.testFixtureWardrobeSeparatesUnlockedAndLockedEquipStates()` —
   expected `正在预览：球场围巾`.
4. `PhoneAppUITests.testLiveOnboardingAndWardrobePersistOfflineAcrossRelaunchAndReset()` —
   equipped scarf was not found after relaunch.
5. `PhoneAppUITests.testNotificationRouteOpensSafeOverviewWithoutSettlingAReward()` —
   expected legacy notification destination was not found.

The combined script stopped before Watch because the iPhone suite failed.

#### Apple Watch UI

- Command: standalone `xcodebuild test`, scheme `WatchCompanion-Watch`,
  `-only-testing:WatchAppUITests`
- Revision: `e4265fe` plus documentation-only working tree
- Simulator: Apple Watch Series 11 46 mm, watchOS 26.5
- Result bundle: `.artifacts/e2e-watch-g0-20260724.xcresult`
- Result: 18 total, 15 passed, 3 failed.

Failed tests:

1. `WatchAppUITests.testAccessibilityAuditAcrossPrimarySurfaces()` —
   accessibility audit assertion failed.
2. `WatchAppUITests.testLiveMainStoryAndHabitPersistWithoutHealthData()` —
   an old main-story/habit persistence assertion failed.
3. `WatchAppUITests.testNotificationRouteNavigatesWithoutSettlingStoryOrHabit()` —
   an old fixed-notification/main-story assertion failed.

The Watch run passed default Mock selection, invalid-Mock fail-closed behavior,
AI local fallback, known-value-only partial health, the fixture and onboarding
paths, and all exercised Touch Exchange cancellation/consent/race paths.

Both Xcode test runs emitted a diagnostics-collection error because a spawned
`xcrun` resolved against the host's default Command Line Tools directory and
could not find `simctl`. The `.xcresult` summaries above are still complete.
The external audit records the host configuration separately.

### NOT RUN

- Dedicated `Scripts/test-accessibility`; contrast failures are already present
  in both platform E2E suites, but this command still needs a fresh result.
- Computer Use visual review of the rebuilt iPhone UI.
- Computer Use visual review of the rebuilt Watch UI.

Computer Use becomes a mandatory G5/G6 gate after the new surfaces exist. The
current historical interface is not accepted as a visual target.

### UNVERIFIED EXTERNAL CAPABILITIES

- Physical HealthKit authorization, samples, and background delivery.
- Physical location and motion sampling.
- Focus and best-effort notification timing.
- Foreground activation after a wrist raise.
- Haptic feel and suppression.
- Paired-device disconnect, retry, and reconciliation.
- Frame pacing, decoded memory, thermal behavior, and battery.
- Two-device Touch Exchange and Nearby Interaction.

The current machine has no connected iPhone or Watch, no Simulator pair, and no
valid signing identity. See `docs/external-capability-audit.md`.

## Release And Mock Boundary Checkpoint

Commit `e4265fe`:

- compiles `mock1`, `mock2`, `mock3`, fixture identifiers, and Mock-only
  behavior only in Debug;
- defaults Debug to Mock 1 and Release to HealthKit;
- keeps the Release HealthKit entry reachable so authorization remains
  possible;
- exposes only HealthKit in the Release data selector;
- defaults peer projection to HealthKit;
- adds Debug and Release conditional tests.

Non-blocking follow-up for later runtime goals:

- test Release upgrade from persisted legacy `"mock1"` / `"mock2"` selections;
- remove the default data-source argument from `PeerStateProjection`;
- make `DebugScenarioSupport` a configuration-level dependency rather than a
  target that future Release changes could link accidentally.

## Review Record

| Review | Revision | Result | Disposition |
| --- | --- | --- | --- |
| Initial UI/runtime audit | `51b9a58` | Found legacy card UI, progression coupling, missing experience-event sync, and incomplete profile isolation | Incorporated into Goal plan |
| Goal-plan reviews | planning tree through `0589370` | Initial P0/P1 issues followed by PASS | Namespace, offline-disable, memory authority, route, and test ownership decisions frozen |
| Release boundary audit | pre-`e4265fe` | Confirmed Release fixture/Mock leak | Fixed |
| Release boundary implementation review | `e4265fe` | Initial Debug-default and HealthKit-entry regressions; final PASS with no P0/P1 | Fixed before commit; P2 follow-ups recorded |
| Route/state inventory | `e4265fe` | Found no typed route, unsafe notification replacement, missing path/profile cleanup, and incomplete cross-state handling | Incorporated into route/state contract |
| External capability audit | `e4265fe` | Simulator toolchain available; no hardware, pair, signing, GPS/Motion implementation, or physical verification | Recorded as UNVERIFIED or NOT IMPLEMENTED |
| First final G0 contract review | working tree before corrective pass | FAIL: 1 P0 and 9 P1 groups covering unreachable device gate, conflicting product authority, unscoped routes, authority domains, offline epochs, deletion, sync schema, notification authority, Chat privacy, and stale evidence matrix | Corrective pass implemented; re-review required |
| Second G0 contract review | first corrected tree | FAIL: no P0; 8 residual P1 groups covering identity ownership, social scope, dependency order, memory excerpt privacy, notification consent, deletion retry/fence, sync-family tests, and stale Mock/testing contracts | Corrective pass implemented; re-review required |
| Third G0 contract review | second corrected tree | FAIL: no P0; one P1 group because SECURITY still allowed raw-HealthKit server exceptions and the active device runbook still required Smart Alarm and legacy growth/story | Security boundary made device-only; runbook rewritten for current Mori; re-review required |
| Fourth G0 contract review | final G0 tree | PASS; no P0/P1 | Approved for scoped commit |

## Recovery Rule

On resume, read this file, verify branch, HEAD, and dirty state, then continue the
first Goal not marked `Committed`. Do not infer PASS from an older revision.
Simulator evidence never satisfies a physical-device gate, and a historical UI
failure never becomes accepted merely because that surface is scheduled for
replacement.
