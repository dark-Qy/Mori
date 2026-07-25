# Mori G8 Foundation Handoff

## Scope

This checkpoint establishes the Mock-first authority and convergence
foundation for G8. It does not yet connect the iPhone and Watch application
stores to one product-loop runtime, and it does not claim a paired Simulator
transport or real `WatchConnectivity`.

G4 motion remains outside this checkpoint. The external black-Mori handoff is
still deferred until the UI composition is stable; white Mori and physical
device playback remain explicitly unverified.

## Delivered

### One Authoritative Ledger

- `ProfileLedgerRepository` is the authority for synchronized product state.
- In-memory and file storage expose SHA-256 revisions and compare-and-swap
  writes.
- Migration, append, sensing mutation, replacement, and concurrent repository
  writes reload and replay after a storage conflict instead of overwriting a
  newer ledger.
- The exact historical Mock bootstrap shape is migrated on read to the typed
  bootstrap deletion root. The legacy digest is recomputed from the historical
  framed inputs; matching a 64-character string is not sufficient.
- Authority and ledger migrations are persisted with CAS, so a paused migration
  cannot discard a concurrent event.

### Task And Coin Settlement

- `TaskSettlementRuntime` writes completion before reward.
- Completion and reward identities are deterministic and retry-safe.
- Startup and post-sync repair recover a completed task whose reward was
  interrupted.
- Concurrent iPhone and Watch completions converge to one settlement credit.
- A ledger write interrupted before outbox persistence is recovered by the
  synchronization runtime.

### Global Preferences, Consent, And Deletion

- Deletion roots are typed; reserved bootstrap identifiers cannot be forged by
  a normal deletion request.
- A newer deletion root atomically resets synchronized preferences and revokes
  old-root consent.
- Consent schema v2 carries its deletion root. Old-root consent cannot win with
  a larger field revision, and future-root consent waits for its preference
  fence.
- A real v1 peer is handled fail-closed: both the old
  `unsupportedSchema(2)` error and the typed incompatibility path trigger a
  bounded v1 fallback using a persisted all-disabled snapshot. Offline errors
  do not revoke consent.
- Global-authority file writes use CAS, preventing stale repositories from
  replacing a newer deletion fence.
- `GlobalDeletionCoordinator` keeps a content-free, durable deletion
  transaction. Same-epoch retries merge obligations monotonically; a newer
  epoch inherits unfinished work.
- Processor retry tickets are acknowledged individually. A processor remains
  pending until every ticket is complete; peer acknowledgements remain
  participant-scoped.
- Concurrent acknowledgements retry CAS conflicts and converge without dropping
  another participant's result.

### Product-Loop Oracle

- `ProductLoopProjection` is a deterministic, content-free view of profile,
  sensing, facts, events, task lifecycle, settlements, coins, collection,
  memory and letter lifecycle, conversation counts, and unresolved events.
- Its digest excludes raw evidence values, health values, narrative, letter
  text, and conversation content.
- The G8 harness uses independent expected manifests, disjoint iPhone and Watch
  causal shards, a Watch-authored event, bidirectional offline/relaunch/
  duplicate/reordered delivery, three fixed seeds, and a fixed golden digest.

## Verified

- CompanionCore: 172 tests in 34 suites.
- AppRuntime: 285 tests in 38 suites.
- Final independent foundation review: PASS, P0=0 and P1=0.
- `Scripts/check`: PASS.
- `Scripts/test-release-boundaries`: PASS.
- iPhone and Watch Simulator builds: Debug and Release PASS.
- `git diff --check`: PASS.

These are package, static, and build results. They do not establish physical
HealthKit, GPS, notification, haptic, background, pairing, or
`WatchConnectivity` behavior.

## Next Integration Boundary

The application checkpoint must:

1. Add a shared `ProductLoopAppRuntime` facade, profile initial-state factory,
   deterministic Mock bootstrap, and collection mutation runtime.
2. Replace `PhoneMockExperienceRepository` and
   `WatchMockExperienceRepository` as product-state authorities; do not
   dual-write.
3. Compose the runtime after the complete selected `RuntimeProfile` is loaded,
   using the existing profile-scoped storage namespace.
4. Reconcile sensing authority on startup and after preference changes.
5. Add a Debug-and-UI-testing-only cross-process relay for experience,
   preference, and consent frames.
6. Add paired Simulator journeys with independent state oracles before calling
   any test cross-device.

Until those steps pass, the existing `Scripts/test-e2e` remains a sequential
iPhone/Watch surface regression, not proof of cross-process synchronization.
