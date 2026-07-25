# Mori Data Deletion Contract

- Status: Frozen for implementation
- Date: 2026-07-24
- Authority: ADR 0003 and `docs/privacy.md`

`删除所有 Mori 数据` is one global, idempotent transaction. It is not a reset
of only the active profile, and it is not complete merely because the current
screen becomes empty.

## Transaction Identity

The request creates a `DeletionEpoch` from a Lamport revision and a stable
request ID. Every local store, peer, outbox, notification scheduler, and enabled
remote processor compares that epoch before accepting older data.

The durable state machine is:

```text
requested
  -> deletionFencePrepared
  -> localContentCleared
  -> peersPending / processorsPending
  -> acknowledged
```

Retries use the same request ID. A newer deletion epoch supersedes an older one.
The app may report `本机数据已删除，等待其他设备` or `等待服务确认`; it cannot report
global completion while reachable peers or processors remain pending.

Before clearing general credentials, the transaction persists a content-free
`DeletionFence` and obtains a deletion-scoped retry ticket from every configured
processor when supported. The fence contains only request ID, deletion epoch,
processor ID, acknowledgement state, and ticket expiry. It lives in an
encrypted `DeletionFenceStore` separate from ordinary app content and is removed
only after acknowledgement and the documented retention window.

If a processor is unreachable or cannot issue a deletion-scoped ticket, the app
retains the minimum encrypted credential needed only by the deletion outbox and
reports the processor pending. That credential is unavailable to normal product
requests. A processor without a safe retry mechanism cannot be enabled for
production release.

## Deletion Inventory

| Authority domain | Delete or reset | Retained minimum |
| --- | --- | --- |
| `GlobalSyncedPreferences` | active profile/Mock scenario, companion sensing, reminder mode, quiet hours, and cached preference projections | deletion epoch and peer acknowledgement only |
| `GlobalConsentState` | remote Chat/context consent, friend sharing, public-pet publication, proactive-notification consent/opt-ins, and consent-bearing onboarding record | deletion epoch; no former consent may be treated as valid |
| `DeviceLocalState` | onboarding presentation, saved routes, sheets, pending event glance, adapter state, capability cache, preview state, diagnostics export, and general local service tokens after deletion fences/tickets are prepared | actual OS permission and the content-free deletion fence/retry ticket remain until resolved |
| Every real and Mock `ProfileState` | selected Mori identity, evidence references, passive events, tasks, cooldowns, coin ledger, collection ownership/equip, memories, letters, conversation messages, conversation summaries, prompt/context index, tone preferences, migrations, and tombstones older than the deletion epoch | content-free deletion marker |
| Synchronization | durable outbox/inbox, retry metadata, application context, transport cache, pending acknowledgement, and obsolete peer snapshots | current deletion message until all reachable peers acknowledge |
| Notifications | every pending daily-memory, letter, legacy, and product notification request and delivered app-owned notification where the platform permits | no content |
| Chat and narration | local response cache, request drafts, conversation summary, selected memory excerpts, and future-prompt indexes | deletion-scoped ticket, redacted request ID, processor acknowledgement, and documented retention exception |
| `SocialState` | published pet card, rendezvous session, relationship and server-held Mori history through the processor deletion endpoint | deletion-scoped ticket, processor acknowledgement, and documented retention exception |
| Files and caches | generated memory art, downloaded cosmetics, thumbnails, temporary files, database journals, and app-owned support exports | bundled assets and source fixtures only |

Mock deletion and scenario reset are narrower operations. They never use this
global transaction and never touch real profile, consent, or production social
state.

## System-Owned Data

The app cannot delete HealthKit records it did not create, revoke Apple system
permissions, erase system notification history that the API does not expose, or
guarantee immediate removal from encrypted device backups and processor backups.
After local deletion it:

- stops adapters and scheduled work;
- discards app-owned identifiers and derived records;
- offers an explicit route to Apple Settings for permission revocation;
- states any documented backup or processor retention honestly.

It never labels an OS permission as revoked until the OS reports that state.

## Peer And Offline Safety

- A peer applies the deletion epoch before any queued experience event.
- Events, route references, preferences, and social projections from an older
  epoch fail closed.
- Reinstall or restore cannot treat a stale peer snapshot as newer than a
  locally persisted or server-returned deletion marker.
- If no peer or remote processor is configured, the corresponding stage is
  `notApplicable`, not a fabricated acknowledgement.
- A peer that remains unreachable keeps global deletion status pending; local
  use may restart only under a new post-deletion profile epoch.

On fresh install, the app creates a new root epoch and performs a fence-first
handshake before importing any peer or processor state. It requests the highest
known deletion fence from its encrypted fence store, configured processors, and
reachable Watch, merges those fences first, then evaluates content. If no
trusted fence survives and a peer offers a profile from a different root epoch,
the app fails closed and does not import it automatically; recovery requires an
explicit future recovery flow outside this Goal. This privacy-first loss of
automatic restore prevents an offline pre-deletion Watch from resurrecting data
after iPhone uninstall/reinstall.

## UI Contract

The iPhone owns the global delete action. The confirmation lists local profiles,
Watch data, conversation, memories, coins/collection, scheduled notifications,
and enabled remote/social state. It explains that Apple Health records and
system permissions are outside app-owned deletion.

Watch cannot initiate global deletion. On receipt of a newer deletion epoch it
clears app-owned content, navigation, and pending presentations, acknowledges,
and returns to onboarding.

## Tests

- empty, partial, malformed, repeated, interrupted, and concurrent deletion;
- deletion while Watch is offline, then reconnect;
- deletion while remote/social processor is offline, then retry;
- deletion ticket/fence survives ordinary content clearing and can retry without
  enabling normal service requests;
- iPhone uninstall/reinstall followed by reconnection to an offline
  pre-deletion Watch cannot restore old content;
- fresh-install fence-first handshake occurs before preference or experience
  import;
- stale outbox, notification, route, Chat summary, memory excerpt, and social
  callback cannot restore or disclose old content;
- every real and Mock profile is removed while bundled fixtures remain;
- system permissions remain truthfully reported and are never presented as
  revoked by the app;
- local-complete, peer-pending, processor-pending, acknowledged, and
  not-applicable UI states;
- repository-owned deletion inventory has a corresponding executable test or an
  explicit external `UNVERIFIED` status.
