# Testing Strategy

## Test philosophy

Tests must prove product invariants, not merely exercise lines. Simulator success is not evidence for physical sensors, haptics, background execution, or UWB. Mocks prove application behavior under a declared scenario; they never prove that Apple hardware supplies that scenario.

## Test layers

### Pure domain unit tests

Cover reducers, rule selection, growth, story transitions, commitment repair, notification budget, context selection, and migrations without Apple frameworks.

Required properties:

- identical input, clock, rules, and random seed produce identical output;
- replaying an event ID does not duplicate state or rewards;
- supported event ordering converges to the documented state;
- missing, partial, and stale health context remains neutral;
- AI output cannot alter authoritative state;
- caps, cooldowns, prerequisites, and deduplication compose correctly;
- no health result removes existing growth;
- main-story access is independent of health performance.

Core rules target at least 90% line coverage, but mutation-resistant assertions and invariant tests are more important than the number alone.

### Property and timeline tests

Run at least 1,000 deterministic timelines across fixed seeds. Include:

- duplicate and late events;
- midnight, daylight-saving transitions, time-zone changes, and clock rollback;
- missing days and long inactivity;
- repeated workouts and reward caps;
- opportunity expiry once issuance and expiry exist as an event or durable domain record;
- accepted, missed, repaired, resized, and released commitments;
- overlapping random-story eligibility;
- persistence after every event;
- fixed legacy fixtures for every migration that the product actually supports.

The CompanionCore product-timeline suite parameterizes fixed seeds `0...999`. Every invariant
assertion includes `seed=<n>`, and Swift Testing associates unexpected throws with the failing seed
argument, so a timeline is reproducible without writing artifacts into the worktree. The corpus
distributes the scenarios above across those seeds; each seed need not contain every scenario, but
aggregate coverage is itself asserted.

The current event and state schemas both started at version 1, so there is no historical production
payload to migrate. The suite verifies fail-closed migration dispatch separately, but must not
fabricate a schema-0 transformer and call it migration coverage. When a real schema 2 is introduced,
the release that adds it must retain a sanitized schema-1 fixture and verify its actual transformer.

Likewise, Phase 1 stores completed daily actions but has no issued-opportunity entity. Missing days
therefore remain absent and neutral; the suite does not label that absence as an expiration test. An
explicit opportunity lifecycle must add issuance, expiry, and late-completion cases before it can be
claimed as covered.

### Adapter contract tests

Every production adapter shares a behavioral contract with its mock:

- `HealthDataSource`: authorized, partial, unavailable, empty, stale, duplicate, and error;
- `StateStore`: atomic save, corruption, migration, retry, and deletion;
- `NotificationScheduler`: denied, scheduled, canceled, expired, duplicate, and deep link;
- `SyncTransport`: disconnected, delayed, duplicated, reordered, conflict, and tombstone;
- `NarrativeProvider`: success, timeout, authentication, rate limit, server error, invalid schema, unsafe content, and oversize output.

### UI tests

Use launch arguments and synthetic fixture IDs. Test both Watch and iPhone surfaces:

- clean launch and onboarding;
- no/partial health data neutral state;
- relevant pet action and source explanation;
- habit completion and state persistence;
- soccer side-story eligibility;
- notification deep link without double settlement;
- unknown Mock scenario fails closed without constructing Apple capabilities;
- notification-consent migration disables legacy implicit opt-in;
- WatchConnectivity activation waits for its callback and incoming revisions stream in order;
- iPhone wardrobe preview, equip, reset, offline queue, and Watch reconciliation;
- AI unavailable and invalid response fallback;
- process termination and relaunch;
- VoiceOver labels, largest supported text, Reduce Motion, high contrast, and non-color cues.

Use stable accessibility identifiers for actions and semantic state. Do not test implementation hierarchy.

The Watch persistence E2E uses `--e2e-offline-runtime` together with `-UITesting`. This keeps the
real event ledger and reducers while intentionally suppressing HealthKit refresh and
WatchConnectivity startup, so the test proves offline main-story/habit settlement without being
coupled to Simulator framework latency. The argument has no effect without `-UITesting`.

The iPhone stateful E2E uses isolated Application Support and UserDefaults namespaces to verify
onboarding, wardrobe preview versus equip, offline persistence across termination, reset, and
relaunch. Notification-route E2E on both surfaces verifies navigation only: opening or dismissing
the message cannot settle a story or habit reward. Package tests separately verify durable outbox
coalescing, relaunch recovery, monotonic revisions, scoped projection/merge, and exact transport
retry idempotency. Cross-device delivery and reconciliation still require a paired-device run.

Repository fixtures are copied from an explicit `.xcfilelist` only into Debug app bundles. Both
Apple clients require the compile-time `DEBUG` condition and the runtime `-UITesting` flag before
they resolve an allowlisted fixture through `DebugScenarioSupport`. `Scripts/test-release-boundaries`
builds the Release iPhone app and embedded Watch app, then rejects fixture resources, fixture
identifiers, E2E storage selectors, offline-runtime selectors, and notification-route launch hooks
in either executable.

### Visual and functional review

For UI changes, use Computer Use or an equivalent visible simulator/device session after automated tests pass. Inspect small and large supported Watch sizes, iPhone sizes, light/dark appearance where applicable, largest text, Reduce Motion, truncation, tap targets, navigation, loading, empty, error, and offline states.

Store only sanitized screenshots or recordings. A review note records destination, OS, scenario, result, and known deviations.

### Physical-device tests

Required for claims about:

- HealthKit real samples and background delivery;
- workout session behavior and high-frequency heart rate;
- haptic feel and delivery;
- smart-alarm background runtime and wake fallback;
- Watch-iPhone disconnection and recovery;
- Nearby Interaction distance and lifecycle.

Follow `docs/device-runbook.md`. Record exact device and OS versions, build revision, permission state, steps, observed timing, and evidence. A pending physical test remains explicitly unverified.

## Phase gates

### Phase 0 exit

- Clean clone builds and tests with one documented command.
- CI passes three consecutive runs.
- Test output leaves the worktree clean.
- Deterministic timeline suite reproduces results.
- Mock scenarios are visibly labeled and unavailable in release UI.
- Every device spike is passed, failed with a documented fallback, or explicitly unverified.
- No secrets, raw health fixtures, signing data, or local Xcode state is tracked.

### Phase 1 exit

- Single-user vertical slice passes ten consecutive simulator E2E runs.
- A second clean-install Computer Use pass produces the same state transitions.
- Real HealthKit reads succeed across allowed, partial/empty, and revoked scenarios.
- Local notification route passes five consecutive physical tests without duplicate reward.
- Three representative workouts and the primary loop are device verified.
- AI/network disabled still provides a complete local flow.
- Restart, migration, connectivity failure, and wardrobe sync are covered.

The simulator and package suites may validate the deterministic mainline, daily-opportunity gate,
and soccer-side-story eligibility before device access. They do not validate that a physical Watch
delivers HealthKit samples in the background; that evidence remains `UNVERIFIED` until the device
runbook is completed.

## Test evidence template

```text
Revision:
Date/time zone:
Target and OS:
Scenario or fixture:
Preconditions/permissions:
Command or steps:
Expected:
Observed:
Result: PASS | FAIL | UNVERIFIED
Evidence location:
Follow-up issue:
```

Never mark `UNVERIFIED` as `PASS` because a mock or simulator behaved correctly.
