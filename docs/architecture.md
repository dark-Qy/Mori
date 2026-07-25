# Architecture

> **Historical implementation architecture — non-authoritative for new product
> work.** This document explains the current prototype and is useful for
> migration. New architecture must follow `PRODUCT.md`, `DESIGN.md`,
> `docs/mori-rebuild-goal-plan.md`, and ADR 0002–0006. G1–G3 will replace this
> file with the implemented Mori domain, profile, synchronization, and
> conversation architecture before those Goals are closed.

## Goals

The architecture must keep the Apple Watch experience functional offline, make product rules deterministic and testable, isolate sensitive platform data, and allow unavailable capabilities to be replaced by clearly labeled mocks without changing domain behavior.

## Product surfaces

| Surface | Responsibility | Non-responsibility |
|---|---|---|
| Apple Watch | Pet home, short interactions, habits, story, local notifications, haptics, health event capture | Complex privacy management, a dense health dashboard |
| iPhone | Simple settings, privacy scopes, history, collections, wardrobe, account recovery | A duplicate pet game or mandatory daily flow |
| Server | Optional synchronization, social authority, APNs later, bounded AI narration gateway | Owning local rules or receiving all health history by default |

There is no desktop, external-display, ring, or NFC surface.

## Dependency direction

```text
Watch UI          iPhone UI          Service handlers
   |                 |                       |
Platform adapters (HealthKit, notifications, connectivity, HTTP, storage)
   |                 |                       |
Application use cases and ports
   |
Pure domain: events, reducers, rules, growth, story, context policy
```

Dependencies point inward. The pure domain does not import SwiftUI, HealthKit, WatchKit, UserNotifications, WatchConnectivity, URLSession, or a concrete database.

## Core abstractions

External concerns are injected behind narrow protocols:

- `Clock` and `CalendarProvider`
- `RandomSource`
- `UUIDSource`
- `HealthDataSource`
- `NotificationScheduler`
- `NarrativeProvider`
- `StateStore`
- `SyncTransport`

Tests use fixed clocks, calendars, UUIDs, and seeded randomness. Production adapters translate framework objects to domain types at the boundary.

## Versioned event ledger

Every durable input is normalized into an event:

```text
Event
  eventID: stable identifier
  schemaVersion: event payload version
  occurredAt: source occurrence time
  recordedAt: local ingestion time
  source: HealthKit, user, notification, sync, or mock
  type: typed discriminator
  payload: validated typed payload
```

Reducers rebuild `PetState`, `GrowthState`, `StoryState`, and `ThemeProgress`. Required properties:

- replaying the same `eventID` is idempotent;
- ordering policy is explicit and stable;
- rule and schema versions are recorded with decisions;
- migrations are forward tested from every supported schema;
- derived state is reproducible from the ledger and configuration.

Store raw HealthKit identifiers only as needed for deduplication and provenance. Do not place raw health payloads in general application logs.

## Authoritative decision pipeline

```text
external sample or action
  -> validate and normalize
  -> append idempotent event
  -> deterministic reducer
  -> rule eligibility and safety checks
  -> seeded scheduling for eligible optional events
  -> state transition and decision trace
  -> local template or validated AI narration
  -> presentation
```

The `DecisionTrace` records relevant rule IDs, rule version, selected theme, rejected alternatives, and reward calculation without copying sensitive raw values into diagnostics.

Rules own:

- health-data freshness and sufficiency;
- quest eligibility, cooldowns, caps, deduplication, and rewards;
- story facts and legal transitions;
- commitment state and repair options;
- quiet hours, notification budget, and sharing scope.

Randomness chooses only among rule-approved options. It never changes reward amounts, core story order, consent, or safety boundaries.

## Health context

`HealthDataSource` returns typed samples with source, timestamp, freshness, and authorization observability. A normalizer handles overlapping devices, duplicates, units, time zones, and late samples. A context builder selects bounded raw windows plus derived features and rule hits for the current decision.

Missing, stale, unavailable, and unauthorized are distinct states. None is interpreted as a negative health outcome. The core experience remains playable without HealthKit.

## Story and growth

Story facts and branch state are deterministic. The common main story preserves the same key chapters and order for everyone; health context may alter presentation and side stories, not access to the core narrative.

Growth is split into vitality, bond, and experience of the world. Each uses different earning rules, caps, deduplication, and cooldowns. AI never calculates or mutates growth.

The current Phase 1 vertical slice implements a seven-beat common mainline, one daily opportunity
settlement, and an explicit-soccer random side-story rule. `PhaseOneProgression` coordinates these
use cases over the event engine; the pure reducer remains authoritative for deduplication and
rewards. Random-story selection uses a stable seed, so persistence replay and repeated refreshes
produce the same answer.

The selective Phase 2 responsibility foundation adds versioned commitment events and a pure state
machine for explicit controllable actions. A missed target becomes a repairable relationship state,
never a health judgment or loss of earned growth. The foundation is persisted and replayable but is
not yet exposed as a Watch or iPhone workflow.

The local initiative planner hashes the approved theme, rule-evaluation timestamp, and canonical
processed-event identities into a 10–90 minute window. Its output remains subordinate to explicit
notification consent, quiet hours, and cooldown policy; narration has no access to the schedule.

## Narration boundary

`NarrativeProvider` accepts a bounded context created after the state transition. In the current
Phase 2 foundation, the upstream model may select only an approved tone; the gateway renders the
actual narration from a reviewed local template.

The decision is schema-validated and the rendered output is length-limited. Direct model-written
health copy, invalid output, a wall-clock timeout, or an unavailable provider falls back to a
deterministic local template. A provider response never becomes an authoritative event by itself.

The provider credential exists only in a server-side gateway environment. The local Phase 2
foundation requires a separate gateway token and an in-process quota. A multi-user deployment must
replace that development token with short-lived user/session authorization and a distributed quota;
Apple clients never receive the upstream provider key.

## Watch-iPhone synchronization

The Watch owns moment-to-moment pet actions. The iPhone owns lightweight management changes such
as wardrobe and notification preferences. Phase 1 keeps authoritative growth events local and
exchanges only a bounded latest-value management projection. Raw health values and
health-sharing scope are not included. The iPhone-owned public pet-card opt-out and game-only
social state are included one way so Watch cannot make those settings more permissive.

- Growth and story merge by event identity.
- Wardrobe selection uses a monotonically increasing revision and deterministic conflict resolution.
- Privacy always resolves to the most restrictive valid state when information is incomplete.
- Deletion and friendship removal are high-priority tombstone events.

The current Phase 1 adapter uses WatchConnectivity application context for latest-value management
state. A file-backed outbox coalesces rapid changes, persists monotonic revisions across relaunch
and clock rollback, and retries pending state on the next local mutation or application start.
The transport treats an exact retry as idempotent while rejecting a conflicting same revision or
an older revision. Incoming values are allowlisted and bounded before the Watch accepts cosmetic
or notification preferences. Full event-queue reconciliation, server sync, and tombstones remain
later milestones and must not be claimed as shipped behavior. Physical disconnect/reconnect timing
also remains unverified until the paired-device runbook passes.

## Touch exchange

The Watch touch-exchange flow is intentionally zero-input: both people open the flow and tap
`开始触碰`. Each Watch creates a temporary Nearby Interaction discovery token and joins a bounded
HTTPS discovery pool. The service may nominate a candidate, but nomination is not proof of
proximity and does not release either public pet card. Public pet-card sharing is enabled by
default, so opening iPhone settings is not a prerequisite. The iPhone-owned opt-out and public
game-only social state are synchronized one way to Watch. Watch does not project those fields back
to iPhone. The projection includes a versioned Phone-authority marker. Until Watch has received and
persisted a valid marker plus setting, the touch-exchange network gate stays closed and the UI says
the automatic sync is still preparing; the user does not need to visit iPhone privacy settings.
A Phone preference-read failure publishes no social authority instead of synthesizing a default.
A previously synchronized opt-out therefore overrides a fresh Watch default across relaunch. A
change made while the devices cannot communicate takes effect when WatchConnectivity delivers it;
receipt during an active flow closes the gate and cancels that flow. The trusted preference gates
the flow before the network client is constructed.

```text
explicit start on both Watches
  -> anonymous temporary candidate discovery
  -> exchange only Nearby Interaction discovery tokens
  -> stable UWB distance samples on both Watches
  -> server verifies overlapping proximity reports
  -> release allowlisted game-only preview
  -> explicit confirmation on both Watches
  -> create the encounter
  -> return one shared, role-specific transfer animation cue
  -> source pet exits Watch A while the same pet enters Watch B
```

An unverified candidate times out and returns to discovery; it never becomes an encounter. The
server stores the temporary token and allowlisted card only for the session TTL. Every
candidate-level request is bound to the current encounter identifier and nonce, so a delayed
proximity or confirmation request from an expired candidate cannot affect a replacement candidate.
After bilateral confirmation, the gateway assigns the first waiting participant the stable
`source` role and the other participant the `destination` role. Both snapshots carry the same
versioned event ID, absolute start time, and duration. Watch A renders the source pet across a
shared left-to-right path; Watch B renders the peer pet from the corresponding off-screen point
to its landing slot. Confirmation order cannot reverse the direction. A consumed-event ledger
prevents status retries or relaunch from replaying the animation, while a client that receives the
cue after its scheduled end uses a short local landing fallback. Reduce Motion replaces travel
with a bounded cross-fade. This presentation cue does not transfer ownership, mutate either pet,
or expand the public-card data contract.

The current MVP uses anonymous installation identifiers and an in-memory gateway, so production
deployment still requires an injected HTTPS `SOCIAL_GATEWAY_BASE_URL`, authenticated identities,
abuse controls, a shared atomic store, and the two-Watch device runbook. Release builds fail when
the HTTPS gateway setting is absent. Apple Watch reports distance rather than direction, and the
app does not claim that the hardware detects literal case-to-case contact.

## Apple capability lifecycle

- HealthKit request state is reconstructed with the system authorization-request status after
  relaunch. This means only that the request sheet has been handled; it never claims a particular
  read permission was granted.
- Notification consent is versioned separately from the preference schema. Legacy implicit opt-in
  fails closed, disabling the preference until a user explicitly enables it.
- Disabling proactive messages cancels the app's pending Mori check-ins. Notification responses
  are parsed at the adapter boundary and routed to a non-settling in-app action; opening a message
  never awards progress by itself.
- Mock and invalid-Mock modes do not read HealthKit or write production event history. The only
  notification exception is an explicit Debug selection of `Mock 2`, which uses an isolated
  cooldown namespace to schedule one labeled ordinary local notification on iPhone.

## Capability degradation

| Capability unavailable | Required behavior |
|---|---|
| HealthKit or permission | Neutral pet state and synthetic demo only when explicitly selected |
| AI or network | Local narration template; identical authoritative state |
| APNs on Personal Team | Local scheduled notification or in-app mock event |
| Smart alarm not device-verified | Fixed local alarm and post-wake summary |
| Nearby Interaction unavailable | No proximity claim; bounded, visibly synthetic mock for testing only |
| Watch-iPhone connectivity | Local queue and later idempotent reconciliation |

## Observability

Use structured logs for event types, rule identifiers, durations, and error categories. Never log raw health values, prompts containing health data, secrets, private messages, or precise social summaries by default. Debug exports must be explicit, redacted, time bounded, and user reviewable.
