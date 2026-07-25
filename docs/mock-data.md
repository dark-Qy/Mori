# Mori Mock Data

This document is the authoritative development-data contract for the Mori
rebuild. Mock is a durable, isolated product profile used to exercise the same
domain reducers and presentation paths as real data. It is never evidence that
an Apple capability works on physical hardware.

## Current Implementation Priority

Mock is the execution priority for the current rebuild checkpoint. A feature is
in scope now when it affects deterministic Mock behavior, persistent profile
isolation, the shared reducers, or the Watch/iPhone presentation path. Physical
sensor fidelity, background execution, paired-device timing, haptic feel,
energy use, and other hardware-only behavior are deferred when they do not
change that Mock path.

The production composition boundary still fails closed and remains covered by
Release checks. Deferral means the physical behavior is `DEVICE_UNVERIFIED`; it
does not permit a Mock implementation to read, write, fall back to, or claim
validation of production data.

## Product Boundary

- Mock controls compile only in Debug builds.
- Every Mock surface persistently displays `模拟数据`.
- Screenshots and recordings retain that label; redacted diagnostics identify
  the fixture and deterministic seed.
- Release builds expose no Mock scenario, fixture selector, launch selector, or
  automatic synthetic fallback.
- An unknown, malformed, or profile-mismatched scenario fails closed. It never
  constructs or falls back to HealthKit, location, motion, notifications,
  remote Chat, narration, WatchConnectivity, or production social services.
- Mock conversation and Touch Exchange are local-only. They cannot publish,
  relate people, notify another person, or send content to production services.
- Simulator and Mock results validate deterministic application behavior only.
  Physical HealthKit, motion, location, background delivery, haptics, energy,
  and paired-device behavior remain `DEVICE_UNVERIFIED`.
- If production evidence is unavailable, production UI uses a neutral no-data
  state rather than synthetic success.
- Presentation-only compatibility fixtures never write production UserDefaults,
  files, event history, permissions, or services.

The Debug product starts with `Mock 1` when no source has been selected. iPhone
and Watch expose a compact source selector for `Apple 健康`, focused Mock
demos including a daily-moments journey, one real-time scene Mock, and five
`35 日` compatibility journeys. A
selection closes the chooser, creates or selects the isolated Mock profile, and
synchronizes only its approved selection authority. Explicitly reselecting the
same Mock creates a new token and profile epoch instead of replaying stale state.

## Profile And Storage Isolation

Every selection is a complete `RuntimeProfile`:

```text
profile ID
+ profile epoch
+ deletion epoch
+ Mock scenario ID
+ winning Lamport selection revision
```

`MockProfileDerivation` deterministically derives the profile and epoch from the
scenario plus the winning revision. A later selection revision creates a new
Mock profile epoch. Offline selections converge by complete Lamport order;
arrival time and wall-clock time are not authority.

`Mock 2` is the one explicit system-notification fixture. On iPhone, a focused
Debug run may opt in with `--enable-mock-system-notification` and schedule one
labeled ordinary care notification after 60 seconds. General UI tests suppress
the system prompt. Normal Apple routing decides whether iPhone delivery mirrors
to Watch; Watch does not schedule a second notification. The selection token
makes scheduling once-per-selection, switching sources cancels it, and its
cooldown store is isolated from production notifications.

`Mock 5` is the daily-moments notification fixture. Its fixed local day contains
three independent visual moments with the polar bear. iPhone seals the eligible
day once through the profile event ledger, while both iPhone and Watch can
schedule one ordinary local notification about 20 seconds after that device
selects the fixture. General UI tests suppress system notification prompts;
focused notification runs opt in with `--enable-mock-system-notification`.
Scheduling is keyed by the selection token, and switching sources cancels the
pending request. The two apps schedule independently: simulator success does
not prove iPhone-to-Watch mirroring, paired delivery, background timing, or
physical-device notification behavior.

`Mock 6` is the sleep-reminder fixture. It contains synthetic recent short
sleep, but no inferred State of Mind. After iPhone explicitly selects the
fixture, iPhone schedules three labeled ordinary local notifications for 10,
20, and 30 seconds from the selection gesture. Their bodies are fixed demo
copy, the selection token makes the batch once-per-selection, and switching
sources cancels pending and in-flight requests in the batch. If notification
permission still needs a user response, an elapsed fire date is delivered at
the system's earliest supported interval after authorization. General UI tests
suppress system notification prompts; focused notification runs opt in with
`--enable-mock-system-notification`. iPhone is the single scheduling owner so
the batch cannot be doubled by both apps. Watch loads the fixture but does not
schedule another local batch; simulator results still do not establish
iPhone-to-Watch mirroring, paired routing, background timing, or
physical-device delivery.

`RuntimeStorageLayout` creates distinct real and Mock parent directories. Raw
profile, scenario, and device identifiers are SHA-256 inputs and never path
components. Each namespace owns separate:

- profile ledger;
- experience outbox;
- cache;
- conversation storage.

## Compatibility Fixture Format And Weekly Memories

Versioned compatibility fixtures are stored separately from user data. Dates
derive from a fixed scenario clock, and expectations are assertions rather than
runtime inputs. Fixtures contain no copied health exports, real names, contact
details, provider keys, device identifiers, or personal conversations.

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

### Daily moments presentation

`Mock 5 · 每日时刻` contains three synthetic moments on one fixed local day:
morning snow, afternoon ice ocean, and a night aurora. Each moment owns its own
time, title, copy, scene, and animation while the fixture selects
`polar_bear` as the character. The iPhone `回忆` tab presents the moments as a
horizontal visual sequence before the independent weekly section. Watch uses a
vertically paged daily-memory surface.

The collection is valid only when its `dayID` equals the scenario clock's local
day. Loading rejects duplicate moments, an unsupported visual identifier, or a
collection outside the bounded 2...8 range. Changing to a fixture with a new
local day replaces the daily sequence instead of presenting yesterday as
today. The domain memory record is composed by the iPhone role, sealed once in
the active Mock profile ledger, and survives runtime recreation.

The same rule applies to behavior-triggered stories. `soccer_workout` provides a synthetic workout;
`SoccerSideStoryRule` derives whether `lost_ball` is eligible from its activity, duration, and
freshness. `expectations.eligibleRandomStory` only validates that derived result and never grants the
eligibility itself. Eligibility also does not force the random story to unlock.

Tasks, cooldowns, coins, collection state, Mori identity, passive events,
memories, letters, and their tombstones live in the profile ledger. A Mock
record cannot validate against a real profile or another Mock epoch.

The filesystem reset primitive requires:

1. the currently selected profile is a valid Mock profile;
2. the requested target exactly matches that selected profile;
3. a valid namespace ownership marker exists;
4. lexical and symlink-resolved containment both succeed.

It refuses real profiles and outside paths, and tests preserve every real byte.
The user-facing reset orchestration must additionally select a newly derived
Mock epoch before stale peer data can be admitted; that orchestration belongs
to the durable preference/synchronization work and must not be replaced by a
filesystem-only reset button.

### Reactive scene demo

`Mock 4 · 实时场景` replays four synthetic telemetry samples in a 16-second loop. The scene rule
receives only GPS-derived speed and heart rate; fixture coordinates stop at the Mock runtime and
are not exposed to presentation. The deterministic thresholds produce:

| Telemetry state | Scene |
|---|---|
| stationary, heart rate below 90 | rainy reading room |
| speed at least 0.6 m/s | spring meadow walk |
| speed at least 2.2 m/s or heart rate at least 120 | summer lake activity |
| stopped with heart rate at least 90 | sunset coast recovery |

Both iPhone and Watch show a persistent `模拟 GPS / 心率` overlay while this demo is active. This
proves the real-time presentation and rule boundary only; it does not claim live Core Location,
workout-session heart rate, background execution, or physical-device sensor validation.

## Compatibility Scenario Catalog

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
| `mock4` | Real-time scene demo | looping synthetic GPS speed and heart rate drive four scene states |
| `mock5` | Polar-bear daily moments | three same-day visual moments refresh by local day, seal on iPhone, and can notify both devices after about 20 seconds |
| `mock6` | Sleep-reminder demo | recent synthetic short sleep and three ordinary reminders at 10-second intervals |
| `mock7_stable` | Five-week stable timeline | recent metrics remain steady across 35 days |
| `mock7_recovery` | Five-week recovery timeline | sleep duration gradually reduces and the latest day enters recovery |
| `mock7_active` | Five-week activity timeline | walking, swimming, badminton, tennis, then soccer; latest soccer workout is eligible for `lost_ball` |
| `mock7_sparse` | Five-week partial timeline | each week preserves its known moments without inventing totals |
| `mock7_rhythm` | Five-week rhythm timeline | sleep-start timing becomes progressively more consistent |

## Runtime Composition

`MoriRuntimeDependencyComposer` validates the complete profile before invoking
any factory.

- A real profile constructs exactly the production dependency for health,
  location, motion, notification, Chat, narration, connectivity, and social.
- A valid Mock profile constructs deterministic local implementations for all
  eight roles.
- An invalid Mock profile constructs nothing.
- Production factories must return the requested role and production
  isolation. A local or wrong-role result fails composition.

This boundary is structural: Mock code has no execution path to an injected
production factory closure.

## Evidence And Sensing

Mock adapters emit the same privacy-minimized `DerivedFactRecord` types as real
adapters. They never manufacture raw HealthKit samples, precise coordinates,
routes, accelerometer streams, contacts, or personal conversations.

Every companion-authorized fact carries the active sensing epoch.
`CompanionSensingCoordinator`:

1. captures the selected profile, sensing epoch, active-since time, and callback
   generation;
2. invalidates old generations before stopping adapters;
3. stops live adapters and invalidates pending presentation when `Mori 随行`
   is disabled;
4. persists enabled authority before starting adapters;
5. revalidates profile and session authority after asynchronous boundaries;
6. degrades stale, pre-enable, disabled, or losing-profile callbacks to
   display-only evidence.

Re-enabling never upgrades or backfills facts observed during the disabled
interval. Display-only facts cannot create passive events, tasks, letters, or
memory eligibility.

## Deterministic Scenarios

The rebuilt runtime provides seven Debug-only scenarios:

| ID | Purpose | Expected inference |
| --- | --- | --- |
| `normal-day` | Representative exact step summary | shared walk, no manufactured task |
| `fast-walking` | Step delta corroborated by broad walking | fast-pace event and confirmable hydration task |
| `walk-and-stop` | Walking followed by stationary | shared pause |
| `late-sleep` | Recent exact sleep duration late in the day | sleep reflection and wind-down recommendation |
| `denied-permission` | Companion activation lacks permission | neutral, no claim |
| `stale-evidence` | Evidence exceeds freshness budget | neutral, no claim |
| `offline-synchronization` | Selected profile remains usable while peer is offline | local shared-walk inference; sync deferred |

For a fixed scenario, app version, rule version, clock, profile, and sensing
epoch, the seed and inference output are identical. Scenario expectations are
test assertions, never runtime inputs that grant eligibility.

Unknown scenario IDs and scenario/profile mismatches resolve to no seed. They do
not choose a default scenario.

## Current UI Migration Boundary

The Watch and iPhone stores use the profile-aware Mori product loop for tasks,
coins, collection state, identity, and scene projection. Historical `Mock 1`,
`Mock 2`, `Mock 3`, `Mock 5`, `Mock 6`, and `mock7_*` fixtures remain as Debug compatibility inputs,
not as an independent product-state authority.

At this boundary:

- legacy selectors must remain Debug-only;
- legacy Mock presentation must not write the real event ledger or invoke
  HealthKit or connectivity; only the explicitly opted-in `Mock 2`, `Mock 5`,
  and `Mock 6`
  notification harnesses may invoke the isolated local-notification paths
  described above;
- new product features must use the profile-aware product loop rather than
  adding view-owned fixture authority; `Mock 5` uses fixture presentation for
  its three images but seals its memory through the profile event ledger;
- historical fixtures do not prove physical or production behavior, paired
  delivery timing, or real Apple capability support.

## Adding A Scenario

1. State the product behavior and privacy invariant it proves.
2. Use synthetic boundary values and a fixed clock.
3. Add it to `MoriMockScenario`; do not add a production fallback.
4. Normalize through the same evidence types used by real adapters.
5. Add deterministic branch and invalid-profile tests.
6. Add a UI journey only after the profile-aware stores are integrated.
7. Keep the `模拟数据` label visible in screenshots and recordings.

Fault cases such as duplicate, delayed, reordered, missing, corrupted, revoked,
offline, time-zone, and restart behavior belong in deterministic tests. They
must change delivery conditions, not bypass domain admission or settlement
rules.

## Conversation Fault Harness

G7 adds a Debug-only, local conversation transport. UI tests may select one
deterministic transport behavior with `--chat-behavior=`:

- `normal`;
- `offline`;
- `timedOut`;
- `rateLimited`;
- `providerFailure`;
- `malformedResponse`;
- `oversizedResponse`;
- `slowStream`.

The selector is accepted only by Debug app composition and is not shown as a
product setting. `Scripts/test-release-boundaries` rejects the selector from
Release executables. None of these modes makes a network request or constructs
a production Chat adapter.

G6 stored preview conversation text and its memory toggle inside the older
Mock-experience file. On first G7 load, that file is rewritten without either
deprecated field. Conversation text now lives only in the active
profile-scoped conversation repository. The Mock memory-context choice is also
profile-local and never expands the global consent used by a future production
transport. Composer drafts are presentation-only: arbitrary text is scanned
before any turn is persisted, so a blocked credential is not restored after
relaunch.

Conversation clear and global deletion use storage revisions and content-free
retirement fences outside the removable profile directories. A stale
repository instance cannot disclose cached text, recreate a cleared file, or
write an inactive profile back after global deletion. Resetting the selected
Mock advances to a fresh profile generation and removes the old owned
namespace; it never deletes real-profile bytes.
