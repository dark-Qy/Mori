# Mori Rebuild Status

## Current Goal

| Field | Value |
| --- | --- |
| Branch | `codex/mori-product-rebuild` |
| Base revision | `51b9a58` |
| Current revision | G6 Mock-first iPhone experience checkpoint |
| Active goal | G7 — Authority-Bounded Mori Conversation; G4 motion merge remains deferred |
| Goal state | G5 and the Mock-first G6 checkpoint are automated, visually verified, and independently reviewed; P0=0, P1=0 |
| Contract | G0–G3, G5, and G6 committed by this checkpoint; black G4 handoff ready but not merged; white Mori deferred |
| Simulator validation | Watch Debug/Release, 23/23 Watch UI tests on 46 mm, 40 mm Watch core journeys, iPhone 17 UI 9/9, iPhone 17e core/a11y journeys, Release boundary, and iPhone Computer Use pass |
| Physical-device validation | UNVERIFIED |

## Goal Ledger

| Goal | State | Revision | Evidence | Blocker / next action |
| --- | --- | --- | --- | --- |
| G0 Product and baseline contract | Committed | `e601225` | Product/design authority, ADR 0001–0006, route/state and deletion contracts, test matrix, capability audit, approved Image2 references, Release-boundary fix, fresh package/app/E2E baseline, four-round independent review | Complete; physical capability remains independently UNVERIFIED |
| G1 Authoritative product domain | Committed | `67f0895` | `MoriDomain` and `MoriPersistence`; profile/epoch/deletion/source isolation; passive-event, task, cooldown, coin, atomic purchase, memory, letter, collection, conversation, Experience and projection contracts; closed canonical codecs; exactly-once legacy reset; 158 tests in 33 suites; two 1,000-case properties; final independent review PASS with no P0/P1 | Complete; Computer Use not applicable because this checkpoint has no UI |
| G2 Evidence and profile runtime | Committed | `92e5486`, `867af19` | Profile-aware `MoriRuntime`; seven deterministic Mock scenarios; normalized bounded evidence; passive inference; global/profile sensing intent fences; isolated real/Mock storage and reset; lazy production adapters and serialized mode switching; Debug 136/136, Release 130/130, CompanionCore 164/164; iPhone/Watch Debug and Release builds; independent review PASS | Complete for Mock-first runtime; physical sensors, background behavior, paired timing, haptics, power, and thermal behavior remain `DEVICE_UNVERIFIED` |
| G3 Sync, reminder, daily memory | Committed | `dba02bd`, `344ff55`, `fe55606`, `c6c1b89` | Durable at-most-once glance fence; deterministic iPhone-owned 22:00 memory sealing; independent GSP/GCS peer sync; automatic experience transfer and Debug paired Mock link; dual-consent notification policy with durable FIFO OS outbox and delivered-state revocation; exact canonical bounded persistence; Debug 214/214, Release 206/206; four app builds; independent final review PASS | Real WatchConnectivity, app-lifecycle and notification-center adapters are deferred to G5/G6 composition; add authority-revocation integration race and long-term fence/outbox compaction |
| G4 Mori motion system | External handoff ready; merge deferred | `codex/mori-motion-g4` / `ef80865` | Black `penguin`: 16 actions, 256 installed assets, Reduce Motion, deterministic priority/interruption/cooldown/recovery/fallback/haptic policy; validator 7/7 and runtime 24/24; independent code/visual review has no blocker | Per current scope, do not merge while establishing the UI; when integrating, remove three legacy placeholder mappings. White `polar_bear` is explicitly deferred and disabled; physical Watch playback remains unverified |
| G5 Watch experience | Committed | `ef8ef2f` | Cardless full-scene home; tap/long-press hierarchy; native companion/settings/letters; one recommended Today task; exact-fact daily memory; isolated durable Mock glance/task receipts; GSP-backed local preferences; real mode fails closed as waiting; AppRuntime 217/217; Watch UI 23/23 on 46 mm; 40 mm layout/a11y journeys; Debug/Release, strict checks, Release boundary, Computer Use, and independent review PASS | Complete for the approved Mock-first scope without G4 motion; physical haptics/background behavior remain `DEVICE_UNVERIFIED`; continue G6 |
| G6 iPhone experience | Mock-first checkpoint committed | This checkpoint | Four-tab native hierarchy; full-scene Mori presence and local Mock conversation; one recommended Today task with exact facts; sealed-memory-only empty state; coin catalog and idempotent purchase/equip; native Settings with companion/reminder/quiet hours, sharing, local data mode, honest automatic-sync status, Apple Settings recovery, and fenced all-data deletion; real/Mock profile isolation; authority-atomic sensing settlement; durable real identity; runtime 7/7, phone unit 17/17, iPhone 17 UI 9/9, and iPhone 17e core/a11y coverage; Debug/Release, strict checks, Release boundary, Computer Use, and independent review PASS | Real conversation processor, remote/social deletion processors, Watch deletion/sync transport, G4 motion, adaptive appearance matrix, and physical-device behavior remain owned by G7–G9 or `DEVICE_UNVERIFIED` |
| G7 Mori conversation | Pending | — | The G6 UI has a bounded local Mock shell; streaming, cancellation, retry, malformed/oversize handling, and authority-bounded real processing remain assigned | Depends on G2, G3 |
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
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` in `Packages/CompanionCore` | G1 product-authority tree | PASS: 158 tests in 33 suites, including two 1,000-case deterministic property suites |
| `Scripts/check` and `git diff --check` | G1 product-authority tree | PASS |
| `Scripts/test` | G1 product-authority tree | PASS: all Swift package suites and iPhone AppSmokeTests |
| `Scripts/test-release-boundaries` | G1 product-authority tree | PASS: Release ships no fixture resources, test selectors, or Mock fixture identifiers |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` in `Packages/CompanionCore` | G2 Mock-first runtime tree | PASS: 164 tests in 34 suites |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` in `Packages/AppRuntime` | G2 Mock-first runtime tree | PASS: 136 tests in 22 suites |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release` in `Packages/AppRuntime` | G2 Mock-first runtime tree | PASS: 130 tests in 21 suites |
| iPhone and Watch app scheme builds, Debug and Release Simulator | G2 Mock-first runtime tree | PASS |
| `Scripts/check` and `git diff --check` | G2 Mock-first runtime tree | PASS: strict Swift/Python lint, credential scan, whitespace |
| `Scripts/test-release-boundaries` | G2 Mock-first runtime tree | PASS: no fixture resources, test selectors, or fixture identifiers ship |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` in `Packages/AppRuntime` | G3 final runtime tree through `c6c1b89` | PASS: 214 tests in 31 suites |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release` in `Packages/AppRuntime` | G3 final runtime tree through `c6c1b89` | PASS: 206 tests in 30 suites |
| `Scripts/check` and `git diff --cached --check` | G3 final runtime tree | PASS: strict Swift/Python lint, credential scan, and whitespace |
| `Scripts/test-release-boundaries` | G3 final runtime tree | PASS: Release ships no fixture resources, test selectors, or fixture identifiers |
| iPhone and Watch app scheme builds, Debug and Release Simulator | G3 final runtime tree | PASS |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/AppRuntime` | G5 Watch tree | PASS: 217 tests in 32 suites |
| Watch Debug and Release generic builds | G5 Watch tree | PASS |
| `WatchAppUITests` on Apple Watch Series 11 46 mm | G5 Watch tree | PASS: 23/23, including primary/secondary accessibility, durable preferences, terminal glance replacement/expiry, one-time Mock reward, real/Mock availability, Today, memory, letters, long-press menu, and Touch Exchange |
| Watch core journeys on Apple Watch SE 3 40 mm | G5 Watch tree | PASS: home, companion settings, daily memory, and primary accessibility audit |
| `Scripts/check`, `Scripts/test-release-boundaries`, and `git diff --check` | G5 Watch tree | PASS; Release contains no fixture resources, selectors, or Mock identifiers |
| Computer Use visual review | G5 Watch tree | PASS on 46 mm home/settings/memory and 40 mm home; no clipping or Mori/text overlap observed |
| Independent G5 review | G5 Watch tree | PASS; P0=0, P1=0 |
| `MoriGlobalPreferenceRuntimeTests` | G6 iPhone tree | PASS: 7/7, including sensing epochs, durable real identity, and deletion-root-preserving real/Mock round trips |
| `PhoneAppTests` | G6 iPhone tree | PASS: 17/17, including source-event cooldowns, at-most-once rewards and purchases, profile isolation, late sensing revocation, collection independence, and fenced global Mock deletion |
| iPhone product UI journeys | G6 iPhone tree | PASS: 9/9 on iPhone 17, covering four-tab hierarchy, cardless Mori home, bounded local conversation, one-coin Today settlement across relaunch, sealed-memory-only history, collection purchase/equip persistence, invalid-Mock fail-closed behavior, settings ownership, and destructive deletion; core hierarchy also passes on iPhone 17e |
| iPhone accessibility audit | G6 iPhone tree | PASS across Mori, Today, Memories, Collection, and Settings on iPhone 17 and iPhone 17e; the iOS 26 audit-only translucent-tab overlap is narrowly identified rather than disabling other categories |
| iPhone Debug and generic Release builds | G6 iPhone tree | PASS without product-source compile warnings |
| `Scripts/check`, `Scripts/test-release-boundaries`, and `git diff --check` | G6 iPhone tree | PASS; Release contains no fixture resources, selectors, or Mock identifiers |
| Computer Use visual and functional review | G6 iPhone tree | PASS for Mori Home, Today, empty Memories, Settings, honest sync state, Apple Settings recovery, and delete-confirmation scope on iPhone 17; small-screen Mori Home and Collection preview also visually pass on iPhone 17e |
| Independent G6 review | G6 iPhone tree | PASS; P0=0, P1=0 after closing late sensing settlement, deletion-root rollback, and durable-real round-trip counterexamples |

### EXACT BASELINE FAILURES

These tests describe the pre-rebuild UI and are not accepted product behavior.
Their G5/G6 replacements now pass; the failures remain below only as exact
historical baseline evidence.

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

#### Apple Watch UI — superseded by G5

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

The G5 replacement suite now passes 23/23 on a 46 mm Watch and its core
journeys pass on 40 mm. The three failures above remain historical baseline
evidence only; the removed legacy main-story and habit assertions are not
current product behavior.

### NOT RUN

- Dedicated `Scripts/test-accessibility`; the rebuilt platform-specific UI
  audits pass, but this aggregate wrapper still needs a fresh result.
- Physical iPhone and Watch validation.

### UNVERIFIED EXTERNAL CAPABILITIES

- Physical HealthKit authorization, samples, and background delivery.
- Physical location and motion sampling.
- Focus and best-effort notification timing.
- Foreground activation after a wrist raise.
- Haptic feel and suppression.
- Paired-device disconnect, retry, and reconciliation.
- Frame pacing, decoded memory, thermal behavior, and battery.
- Two-device Touch Exchange and Nearby Interaction.

`CompanionCore` package tests in Release configuration also remain a
non-blocking repository follow-up: existing test sources directly reference
`#if DEBUG` MockKit types and therefore do not compile as Release tests. The
product iPhone and Watch Release schemes and the dedicated Release boundary
gate pass.

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
| Initial G1 authority review | first G1 tree | FAIL: six P1 groups across derived-fact provenance, recursive lifecycle validation, source isolation, terminal replay, canonical coin/reversal behavior, and schema-shape fixtures | Every counterexample reproduced, fixed, and converted to regression coverage |
| G1 corrective review | final G1 tree | PASS; P0=0, P1=0 | 158 tests/33 suites, both 1,000-case properties, static checks, canonical fixtures, and adversarial probes passed |
| G2 runtime reviews | iterative G2 tree | Initial P1 findings covered canonical identity framing, post-enable HealthKit windows, storage symlink boundaries, concurrent repository writes, stale selection reservations, production-adapter TOCTOU, peer-listener lifetime, sensing epoch ordering, and cross-profile stale requests | Each counterexample fixed and covered before checkpoint |
| G2 final corrective review | final G2 Mock-first runtime tree | PASS; P0=0, P1=0 | Debug 136/136, Release 130/130, CompanionCore 164/164, strict checks, Release boundary, and all iPhone/Watch builds passed |
| Initial G3 cross-module review | first complete G3 tree | FAIL: P0=0, P1=3 across delivered-notification cancellation, glance relaunch at-most-once, and independent GSP revoke convergence | Durable delivered state, presentation fence, and per-register conservative merge implemented with regression coverage |
| G3 notification corrective reviews | corrected notification tree | Initial FIFO, orphaned pending, late delivered callback, and 128-entry history-rollover failures; final PASS with P0=0, P1=0 | Typed FIFO head only; exact pending/delivered history; delivered revocation; schema v2; 130-day rollover test |
| G3 final cross-module review | final tree through `c6c1b89` | PASS; P0=0, P1=0 | Debug targeted 63/63, Release targeted 61/61; all original P1 findings and exact canonical/size boundaries closed |
| Initial G5 Watch UI review | first rebuilt Watch tree | FAIL: P0=0, P1=6 | Closed persistence/availability, evidence-grounded memory, reward authority, haptic duplication, permission wording, and quiet-hour validity; added durable restart coverage |
| G5 boundary re-review | corrected Watch tree | FAIL: P0=0, P1=2 | Bound availability to Mock profiles; atomically terminalized presented, replaced, expired, disabled, and invalid glance candidates |
| G5 final review | final Watch tree | PASS; P0=0, P1=0 | 217 runtime tests, 23 Watch UI tests, 40 mm coverage, Debug/Release, strict checks, Release boundary, Computer Use, and exact Mock/real fail-closed behavior passed |
| Initial G6 iPhone review | first complete Mock-first iPhone tree | FAIL: P0=0, P1=4 | Closed stale-sensing settlement, cross-profile presentation leakage, fenced full deletion plus Apple Settings recovery, and strict lint |
| G6 authority/deletion re-review | first corrected iPhone tree | FAIL: P0=0, P1=2 | Made sensing validation and synchronous ledger settlement one authority-actor operation; preserved deletion roots across profile switches |
| G6 durable-real re-review | second corrected iPhone tree | FAIL: P0=0, P1=1 | Reproduced and fixed normal `real → Mock → real` identity loss; real storage now derives stably from the deletion root |
| G6 final review | final Mock-first iPhone tree | PASS; P0=0, P1=0 | Runtime 7/7, Phone tests 17/17, product UI and accessibility journeys, Debug/Release, strict checks, Release boundary, Computer Use, and all three exact counterexamples passed |

The G1 reviewer recorded one non-blocking G2/G3 follow-up: the inference and
daily-memory authority must bind memory eligibility to sensing/source-event
authority so a disabled `Mori 随行` interval cannot create a memory or be
backfilled after re-enable. G1's generic memory record alone does not prove this
runtime privacy behavior.

G6 keeps three explicit non-blocking follow-ups:

- before Watch deletion transport is enabled, peer merge must reject a newer
  selection revision that carries an older deletion root;
- replace the current tested 112-point phone-page bottom reserve with a
  tab-bar/safe-area-derived value when the deployment API can express it
  consistently across supported systems;
- narrow the remaining iOS 26 native-Form contrast exemption as XCTest's
  standard-control reporting becomes stable.

## Recovery Rule

On resume, read this file, verify branch, HEAD, and dirty state, then continue
the explicitly named Active goal. G4 is intentionally deferred despite not
being merged. Do not infer PASS from an older revision.
Simulator evidence never satisfies a physical-device gate, and a historical UI
failure never becomes accepted merely because that surface is scheduled for
replacement.
