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

`RuntimeStorageLayout` creates distinct real and Mock parent directories. Raw
profile, scenario, and device identifiers are SHA-256 inputs and never path
components. Each namespace owns separate:

- profile ledger;
- experience outbox;
- cache;
- conversation storage.

Tasks, cooldowns, coins, collection state, Mori identity, passive events,
memories, letters, and their tombstones live in the profile ledger. A Mock
record cannot validate against a real profile or another Mock epoch.

The filesystem reset primitive requires:

- the currently selected profile to be a valid Mock profile;
- an exact selected-profile match;
- a valid namespace ownership marker;
- lexical and symlink-resolved containment.

It refuses real profiles and outside paths, and tests preserve every real byte.
The user-facing reset orchestration must additionally select a newly derived
Mock epoch before stale peer data can be admitted; that orchestration belongs
to the durable preference/synchronization work and must not be replaced by a
filesystem-only reset button.

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

The existing prototype screens still contain historical `Mock 1`, `Mock 2`, and
`Mock 3` presentation fixtures. They remain only until G5/G6 replace the Watch
and iPhone stores with the profile-aware Mori runtime.

During that migration:

- legacy selectors must remain Debug-only;
- legacy Mock presentation must not write the real event ledger or invoke
  HealthKit, notifications, or connectivity;
- new product features must use the seven scenarios above rather than adding
  more view-owned fixture state;
- no historical fixture is accepted as evidence that durable profile switching
  or cross-device synchronization is complete.

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
