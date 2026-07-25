# ADR 0004: Experience-event synchronization

- Status: Accepted
- Date: 2026-07-24

## Context

The existing WatchConnectivity projection synchronizes latest management state.
The rebuilt product also needs tasks, rewards, memories, letters, reminder
consumption, and memory references used by conversation to converge without
transferring raw health or location data. Conversation messages and summaries
remain in the iPhone profile repository. Treating the synchronized records as
preference fields would lose identity, replay safety, and causal history.

## Decision

Management preferences and experience events use separate synchronization
channels:

- the preference channel is a latest-value register for
  `GlobalSyncedPreferences`;
- the experience channel is an append-only, profile-scoped event envelope with
  stable identity and idempotent merge.

The only cross-device experience schema is `ExperienceSyncEnvelope`. Every
envelope contains:

- schema version;
- event ID and event type;
- profile ID, complete profile epoch, deletion epoch, and explicit real or Mock
  profile source;
- origin device ID and logical origin sequence;
- logical revision;
- observed and authored times for grouping and explanation, never authority;
- approved derived payload;
- optional source-event and settlement IDs;
- privacy classification;
- an explicit tombstone flag and tombstone reason when the event deletes or
  invalidates another record.

The envelope may contain derived product facts such as step total, sleep
duration, broad event type, task lifecycle, coin transaction, memory reference,
or letter state. Each derived fact carries either `displayOnly` authorization
or the exact sensing epoch that permits companion use. Each sealed-memory fact
reference names both its evidence ID and the memory-eligible passive event that
accepted that evidence. It never contains raw HealthKit samples, precise
coordinates, GPS tracks, contact data, secrets, or provider credentials.

Reducers sort by canonical logical identity, ignore exact duplicates, and fail
closed on conflicting reuse of an event ID. Delivery uses a durable outbox and
acknowledgement; transport retries the same bytes.

## Synchronized record ownership

| Event family | Author | Merge direction | Tombstone / authority |
| --- | --- | --- | --- |
| Approved passive event | Device that owns the evidence adapter | Both directions | Carries sensing epoch; never raw evidence |
| Task issued, completed, expired | Shared reducer on either device | Both directions | Source-event and settlement IDs make replay idempotent |
| Coin earn and reversal | Shared reducer on either device | Both directions | Transaction ID is authoritative |
| Selected Mori identity, cosmetic purchase, equip | Shared reducer on either device | Both directions | A purchase is one atomic payload containing its debit and ownership grant; split purchase debit/ownership events are invalid |
| Daily memory sealed or deleted | iPhone daily-memory authority | iPhone to Watch; deletion acknowledgement returns | One deterministic ID; Watch never persists a competing record |
| Letter delivered, read, deleted | Originating rule engine; read/delete on either device | Both directions | Stable letter ID and explicit delete tombstone |
| Reminder presented, expired, replaced | Watch presentation reducer | Watch to iPhone | Does not delete memory eligibility |
| Conversation messages and summaries | iPhone profile repository | Not synchronized to Watch | Governed by profile and deletion epoch |
| Friend relationship and public pet card | Social service | Outside this envelope | Governed by `SocialState` and processor deletion |
| Global preferences and consent | Preference/consent reducers | Separate latest-value channels | Never encoded as an experience event |

Reminder presentation state and durable memory state remain separate. A Watch
may consume or expire a glance without deleting the event's eligibility for the
shared daily memory.

## Notification and haptic authority

| Kind | Authority | Stable identity | Delivery and cancellation policy |
| --- | --- | --- | --- |
| Daily memory | iPhone only | `daily-memory/<profile>/<epoch>/<local-day>` | Requires current GCS daily-memory opt-in and current iPhone OS authorization in DLS; at most once per local day, best effort after 22:00, obey quiet hours, and cancel on consent revocation, deletion, profile change, or revised sealed record |
| Mori letter | iPhone only after a durable `LetterRecord` exists | `letter/<profile>/<epoch>/<letter-id>` | Requires current GCS letter opt-in and current iPhone OS authorization in DLS; one letter notification per day, six-hour letter cooldown, and total product budget of two notifications per day; obey quiet hours and cancel on consent revocation, read, delete, profile change, or deletion epoch; Watch never schedules a duplicate |
| Passive `抬腕提醒` | Watch foreground activation reducer | pending event ID | No system notification; present once on the next eligible activation, then consume, replace, or expire |
| Passive `轻震提醒` | Watch foreground runtime only | pending event ID | One best-effort haptic when the eligible glance is actually presented and quiet hours permit; no background-haptic promise and no retroactive vibration |

This Goal does not schedule autonomous task notifications. Tasks remain
discoverable in Today and may be proposed in Mori conversation. Adding a task
notification later requires a separate product and consent decision.

The daily memory or letter remains available in its normal destination when a
notification is unauthorized, suppressed, budgeted out, delayed, or missed.
App-level consent defaults off and is distinct from OS authorization.

## Conflict rules

- Deletion epochs and winning profile epochs outrank older experience events.
- Preference disable revisions reject every not-yet-accepted passive event from
  a superseded sensing epoch. `effectiveAt` is not used to authorize an old
  event; ambiguous causal order fails closed.
- Display-only facts cannot be reclassified into companion facts after
  re-enable; memory sealing rejects facts without an accepted eligible source
  event in the same authorized sensing epoch.
- Coin settlement IDs and task source-event IDs are unique and idempotent.
- Competing cosmetic purchases converge to one canonical ownership and one
  debit; a loser is a consumed no-op, never a second charge.
- Sealed daily memories are not silently rewritten by late evidence.
- Unknown schemas, event types, profile IDs, or privacy classes fail closed.

## Consequences

The product gains deterministic offline convergence and a reviewable privacy
boundary at the cost of a second sync pipeline. UI code observes derived
projections and never mutates synchronized dictionaries directly.

## Validation

- Reducer tests cover reordering, duplication, conflict, clock rollback,
  deletion, epoch loss, and reconnect.
- Transport tests prove exact-byte retry and durable acknowledgement.
- Privacy tests reject forbidden payload keys and oversized envelopes.
- Multi-device E2E verifies tasks, coins, memory, and reminder consumption after
  disconnect and reconnect.
