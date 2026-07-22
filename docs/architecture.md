# Architecture

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

The Watch owns moment-to-moment pet actions and queues events while disconnected. The iPhone owns management changes such as wardrobe and privacy settings. Both exchange versioned, idempotent events.

- Growth and story merge by event identity.
- Wardrobe selection uses a monotonically increasing revision and deterministic conflict resolution.
- Privacy always resolves to the most restrictive valid state when information is incomplete.
- Deletion and friendship removal are high-priority tombstone events.

The current Phase 1 adapter uses WatchConnectivity application context for latest-value
management state. It waits for session activation, emits incoming revisions as a stream, rejects
stale revisions, and keeps Watch-local health and growth authoritative while accepting iPhone
cosmetic and notification preferences. Full event-queue reconciliation and tombstones remain a
later milestone and must not be claimed as shipped behavior.

## Apple capability lifecycle

- HealthKit request state is reconstructed with the system authorization-request status after
  relaunch. This means only that the request sheet has been handled; it never claims a particular
  read permission was granted.
- Notification consent is versioned separately from the preference schema. Legacy implicit opt-in
  fails closed, disabling the preference until a user explicitly enables it.
- Disabling proactive messages cancels the app's pending Mori check-ins. Notification responses
  are parsed at the adapter boundary and routed to a non-settling in-app action; opening a message
  never awards progress by itself.
- Mock and invalid-Mock modes do not construct the HealthKit, notification, persistence, or
  WatchConnectivity runtime.

## Capability degradation

| Capability unavailable | Required behavior |
|---|---|
| HealthKit or permission | Neutral pet state and synthetic demo only when explicitly selected |
| AI or network | Local narration template; identical authoritative state |
| APNs on Personal Team | Local scheduled notification or in-app mock event |
| Smart alarm not device-verified | Fixed local alarm and post-wake summary |
| Nearby Interaction unavailable | No proximity claim; bounded mock or mutual short-code flow for testing |
| Watch-iPhone connectivity | Local queue and later idempotent reconciliation |

## Observability

Use structured logs for event types, rule identifiers, durations, and error categories. Never log raw health values, prompts containing health data, secrets, private messages, or precise social summaries by default. Debug exports must be explicit, redacted, time bounded, and user reviewable.
