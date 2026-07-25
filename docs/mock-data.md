# Mock Data

## Purpose

Mocks make deterministic development possible when HealthKit history, physical hardware, APNs, AI, or proximity is unavailable. A mock is a product-development mode, not evidence that the real capability works.

## Non-negotiable labeling

- Every debug screen using synthetic data displays **Demo Data** or **模拟数据** persistently.
- Screenshots and recordings retain that label.
- Debug diagnostics identify the fixture and random seed.
- Release builds do not expose fixture selection or silently substitute synthetic health data.
- If production data is unavailable, production UI uses a neutral no-data state rather than a fake successful state.
- An unknown Mock scenario fails closed into a labeled neutral error state and never falls back to
  live HealthKit or other Apple capabilities.
- Mock application stores use in-memory presentation state only; changing a Mock wardrobe or
  privacy control must not mutate live UserDefaults, files, or production event history.
- `Mock 2` is the only notification exception: selecting it is an explicit Debug action that may
  request notification permission and schedule one labeled, time-sensitive local care message
  after 60 seconds. Switching data sources cancels the pending Mock notification. Its cooldown
  storage is isolated from production notifications, so a demo cannot suppress a later real message.

## Interactive demo selector

The current debug product build starts with `Mock 1` when no data source has been selected. Both
iPhone and Watch expose one compact data-source button with `Apple 健康`, the three focused Mock
demos, and five `35 日` demos. A single tap applies the selection, closes the chooser, remembers only
the selected label, and projects that label through the existing WatchConnectivity state.

Mock world state remains in memory. Selecting a fixture again or relaunching reconstructs its
canonical initial state instead of persisting interactions into the next demonstration.

`Mock 2` schedules its 60-second system notification on iPhone. The paired Watch keeps the same
in-app care-message timeline; normal Apple notification routing decides whether the iPhone alert
is mirrored to Watch. General UI-test launches suppress the system permission prompt; a focused
notification run opts in with `--enable-mock-system-notification`. The system notification is
scheduled once for each data-source selection token: relaunching does not send it again, while
explicitly selecting `Mock 2` again creates a new token and resets the 60-second notification.

## Fixture format

Fixtures use versioned JSON stored separately from user data:

```json
{
  "schemaVersion": 1,
  "scenarioID": "health_normal",
  "displayName": "Normal recent health data",
  "clock": {
    "now": "2026-07-23T09:00:00+08:00",
    "timeZone": "Asia/Shanghai"
  },
  "launchArguments": ["-MockScenario", "health_normal"],
  "state": {},
  "expectations": { "primaryState": "petHome", "mockBadgeVisible": true }
}
```

`ScenarioFixture` validates the envelope. `MockScenarioRuntime` converts it into typed health,
permission, service, wardrobe, and pet state. `MockScenarioRun` owns a deterministic clock, event
ledger, and replayable reducer. A fixture that cannot enter this executable path fails the core
test suite.

Installation state and executable domain state derive the initial screen. For example,
`hasLaunchedBefore: false` produces onboarding, while a created pet produces the pet home. The
`expectations.primaryState` field validates that derived result; it is never used as runtime input.
`fresh_install` begins with a truly empty event ledger, so onboarding cannot inherit synthetic
progress accidentally.

Multi-day fixtures use `state.health.dailySnapshots`. Each entry becomes one normalized
`HealthSnapshot` and one `healthSnapshotReceived` event at that entry's `capturedAt` time. The five
`mock7_*` scenarios each contain 35 days, which the iPhone presentation divides into five complete
seven-day memories. The rule engine may still analyze the most recent seven days against its
30-day baseline. Missing metrics remain `null`; they are never converted to zero.

```json
"health": {
  "source": "mock",
  "dataState": "available",
  "dailySnapshots": [
    {
      "capturedAt": "2026-07-23T20:00:00+08:00",
      "sleepMinutes": 420,
      "sleepWindowStart": "2026-07-22T23:00:00+08:00",
      "sleepWindowEnd": "2026-07-23T06:00:00+08:00",
      "steps": 6700,
      "activeMinutes": 30
    }
  ]
}
```

Optional `expectations.trend` values are assertions, not presentation inputs. Loading the fixture
fails if the analyzer does not produce the declared recent-day count, usable baseline count, or
metric status.

### Weekly memory presentation

The iPhone `回忆` tab builds five weekly memories locally and deterministically for `mock7_*`
fixtures. Each report comes directly from that week's raw snapshots and shows concrete totals for
steps and active minutes plus average sleep when all seven values exist. Workout records provide
event highlights such as `游泳 · 25 分钟`, `羽毛球 · 30 分钟`, `网球 · 40 分钟`, or
`足球 · 45 分钟`. The UI does not expose comparison-baseline language,
missing-value implementation notes, or model/provider labels.

Ten reviewed Codex image2 covers include walking and route scenes, evening rhythm, rest, swimming,
badminton, tennis, and soccer. Every timeline entry selects a cover that matches its weekly facts;
the active journey uses five distinct activities and color palettes instead of repeating walking
scenes.
Precise dates and numbers remain native text rather than being baked into generated artwork. No
runtime model or network request participates in this path.

The same rule applies to behavior-triggered stories. `soccer_workout` provides a synthetic workout;
`SoccerSideStoryRule` derives whether `lost_ball` is eligible from its activity, duration, and
freshness. `expectations.eligibleRandomStory` only validates that derived result and never grants the
eligibility itself. Eligibility also does not force the random story to unlock.

Dates are interpreted relative to `clock.now` where possible. Fixtures never contain copied health exports, real names, contact details, provider keys, device identifiers, or personal conversations.

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
| `mock1` | Everyday demo | normal sleep and activity |
| `mock2` | Relationship and care demo | three complete days without interaction plus an explicitly logged stressful State of Mind |
| `mock3` | High-activity story demo | high activity and an explicit soccer workout eligible for `lost_ball` |
| `mock7_stable` | Five-week stable timeline | recent metrics remain steady across 35 days |
| `mock7_recovery` | Five-week recovery timeline | sleep duration gradually reduces and the latest day enters recovery |
| `mock7_active` | Five-week activity timeline | walking, swimming, badminton, tennis, then soccer; latest soccer workout is eligible for `lost_ball` |
| `mock7_sparse` | Five-week partial timeline | each week preserves its known moments without inventing totals |
| `mock7_rhythm` | Five-week rhythm timeline | sleep-start timing becomes progressively more consistent |

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
