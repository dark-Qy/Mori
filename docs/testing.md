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
- expired opportunities;
- accepted, missed, repaired, resized, and released commitments;
- overlapping random-story eligibility;
- persistence and migration after every event.

Persist failing seeds so failures are reproducible.

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
- iPhone wardrobe preview, equip, reset, offline queue, and Watch reconciliation;
- AI unavailable and invalid response fallback;
- process termination and relaunch;
- VoiceOver labels, largest supported text, Reduce Motion, high contrast, and non-color cues.

Use stable accessibility identifiers for actions and semantic state. Do not test implementation hierarchy.

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
