# ADR 0003: Real and Mock profile isolation

- Status: Accepted
- Date: 2026-07-24

## Context

The development team needs deterministic Mock scenarios on both iPhone and
Apple Watch. Mock data must exercise the same product flows as real data without
being mistaken for HealthKit history, earning rewards in the real profile, or
restoring deleted real state through synchronization.

The legacy implementation stores a single data-source enum and projects it
through WatchConnectivity. That is sufficient for the current prototype but not
for the rebuilt product.

## Decision

Persistence and external effects are split into five authority domains:

- `GlobalSyncedPreferences` contains active profile selection, Mock scenario,
  companion sensing, reminder mode, and quiet hours.
  Every mutation has a Lamport-style
  `PreferenceRevision(counter, originDeviceID)`. Profile, Mock, and sensing
  epochs use that complete winning revision identity.
- `GlobalConsentState` contains versioned remote-Chat/context consent, friend
  sharing, public-pet publication, proactive-notification consent version,
  daily-memory/letter notification opt-ins, and consent-bearing onboarding
  disclosures. Either device may revoke immediately. Only iPhone may expand
  remote disclosure or proactive notification after explicit consent.
  Concurrent consent merges most-restrictive first, then uses the logical
  revision for equal choices.
- `DeviceLocalState` contains current-device HealthKit, location, motion,
  notification, and background capability plus local onboarding presentation,
  route restoration, pending UI, and adapter state. It is never synchronized as
  if it applied to the peer.
- `ProfileState` contains selected Mori identity, tasks, coins, collection,
  equipped cosmetics, memories, letters, conversation, tone preferences, and
  the experience ledger for exactly one profile.
- `SocialState` is production relationship and public-card state owned by the
  social service when that service is enabled, with a minimal local projection
  and deletion status. It is not an experience-event payload.

There is one durable real profile and at most one active development Mock
profile epoch. A Mock profile records `profileID`, `selectionEpoch`, and
`seededFromScenarioID`. Changing the Mock scenario creates an epoch from the
winning selection revision and deterministically reseeds only Mock state. Two
offline devices therefore cannot create the same epoch merely by incrementing
the same local integer.

All domain events, outbox operations, reward settlements, and deletions carry
their profile ID and complete epoch. Reducers reject cross-profile input and
events from a losing or deleted epoch.

A Mock profile uses deterministic isolated implementations for health,
location, motion, notification, Watch connectivity, Chat, narration, and social
exchange. It cannot construct a production social gateway, publish a real pet
card, create a relationship, send remote conversation, or mutate real consent.

Debug builds expose the Mock selector on both devices. Release builds compile
out fixture cases, resources, launch selectors, and Mock-only behavior while
retaining the Apple Health connection entry.

## Conflict and deletion rules

- Concurrent profile selections compare the complete Lamport revision. Wall
  clock is never an authority.
- A peer receiving a winning Mock epoch discards events from every losing epoch.
- Companion disable establishes a new sensing epoch. Once received, a device
  rejects all not-yet-accepted passive work from older epochs; `effectiveAt` is
  display/audit metadata only. Ambiguous causal order fails closed.
- `Delete all Mori data` executes the global transaction in
  `docs/mori-data-deletion-contract.md`, increments a durable deletion epoch,
  and persists its content-free marker until peers and enabled processors
  acknowledge it.
- A delayed offline peer cannot restore an older epoch after deletion.
- Switching between real and Mock never copies tasks, coins, memories,
  conversation, collection, social state, consent, or reward settlements.

## Consequences

Storage and synchronization require explicit profile context. This is more
verbose than a global repository but makes test data, deletion, and reward
integrity auditable. The current `CompanionDataSource` compatibility layer is
temporary and will be removed after the versioned development reset.

## Validation

- Debug and Release builds have separate compile-boundary tests.
- Property tests mix real, Mock, offline, duplicate, late, and deletion events
  and prove that state never crosses profiles or epochs.
- E2E tests switch scenarios on both devices, reconnect after conflicting
  offline changes, delete all data, and relaunch.
- Release binaries are scanned for fixtures and test launch selectors.
