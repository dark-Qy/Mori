# Mori Route And State Contract

- Status: Frozen for implementation
- Date: 2026-07-24
- Applies to: G1–G8 of `docs/mori-rebuild-goal-plan.md`

This document defines navigation ownership, notification resolution, and
cross-surface states for the rebuilt Mori product. It is an implementation
contract rather than a screenshot inventory.

## Routing Rules

- A route carries stable identifiers and immutable context values only. It never
  owns a feature model, reward decision, sensor sample, or mutable domain
  object.
- Push navigation, sheets, destructive confirmation, and transient overlays use
  separate state. A sheet is not encoded into a navigation path.
- A router may select a destination. It cannot create or complete a task, settle
  a reward, purchase an item, compose a memory, or infer a fact.
- Every profile-scoped object route and mutating presentation captures the
  profile ID and epoch that produced it. Resolution and confirmation both
  compare that context with the active profile. A mismatch fails closed at the
  nearest safe root.
- Unknown, malformed, deleted, or obsolete routes are safe no-ops with redacted
  diagnostics.
- Changing profile clears paths and presentations that refer to the former
  profile. It does not copy state between profiles.
- Each iPhone tab owns its navigation path. Opening and closing Settings restores
  the originating tab and path.

## Route Types

The concrete Swift names may vary, but their semantics and ownership must not.

```swift
struct ProfileRouteRef<ID: Hashable & Codable>: Hashable, Codable {
    let profileID: ProfileID
    let epoch: ProfileEpoch
    let id: ID
}

enum WatchRoute: Hashable, Codable {
    case today
    case task(ProfileRouteRef<TaskID>)
    case dailyMemory(ProfileRouteRef<MemoryID>)
    case letters
    case letter(ProfileRouteRef<LetterID>)
    case touchExchange
    case settings
    case dataAndPermissions
    case dataMode
    case mockScenario
}

enum PhoneTab: String, Hashable, Codable {
    case mori
    case today
    case memories
    case collection
}

enum PhoneRoute: Hashable, Codable {
    case task(ProfileRouteRef<TaskID>)
    case memory(ProfileRouteRef<MemoryID>)
    case letter(ProfileRouteRef<LetterID>)
    case collectionItem(ProfileRouteRef<CosmeticID>)
    case settings
    case companionSettings
    case dataAndPermissions
    case conversationSettings
    case dataMode
    case mockScenario
    case friendSharing
}
```

Transient presentations remain separate:

```swift
enum WatchPresentation {
    case eventGlance(ProfileRouteRef<EventID>)
    case companionQuickSettings
    case companionMenu
    case resetMockConfirmation(ProfileRouteRef<MockScenarioID>)
}

enum PhonePresentation {
    case taskProposal(ProfileRouteRef<ProposalID>)
    case purchase(ProfileRouteRef<CosmeticID>)
    case clearConversation(ProfileRouteRef<ConversationID>)
    case deleteMemory(ProfileRouteRef<MemoryID>)
    case resetMock(ProfileRouteRef<MockScenarioID>)
    case deleteAllMoriData(expectedDeletionEpoch: DeletionEpoch)
}
```

`deleteAllMoriData` is global rather than profile-scoped. Its confirmation
captures the expected deletion epoch and revalidates it before incrementing the
authoritative epoch. Profile switch, reset, deletion, or epoch change invalidates
any pending mutating presentation.

## Data Ownership

The route tables use these abbreviations:

- `GSP`: `GlobalSyncedPreferences`
- `GCS`: `GlobalConsentState`
- `DLS`: `DeviceLocalState`, including current-device capabilities and routes
- `PS`: active real or Mock `ProfileState`
- `SS`: real production `SocialState` or isolated deterministic Mock projection
- `TP`: in-memory transient presentation
- `OS`: Apple system settings

## Apple Watch Route Map

| Route / presentation | Entry and return | Authoritative responsibility | Required states |
| --- | --- | --- | --- |
| Launch | App start; resolves onboarding, restored route, or Home | Load GSP, GCS, DLS, active PS, and route snapshot | loading, invalid Mock, missing route |
| Onboarding | First use or deletion; completes to Home | Write local presentation state and explicit versioned disclosures; do not request permissions automatically | loading, offline, invalid Mock |
| Home | Root and safe fallback | Read companion preference, permitted current facts, and Mori projection; write only explicit interaction and presentation state | loading, empty, partial/denied, stale, offline, invalid Mock, sync waiting |
| `eventGlance` | Next foreground activation while eligible; returns automatically to Home | Render one action and bubble; mark pending event presented, expired, or replaced | empty, stale, offline, invalid Mock, missing ID |
| `companionQuickSettings` | Tap `Mori 随行中`; dismisses to Home | Write companion sensing, reminder mode, and quiet hours; stop or resume local adapters immediately | loading, denied, offline, invalid Mock, sync waiting |
| `companionMenu` | Long press Mori, visible alternative, or VoiceOver action | Present Today, Mori Letters, Touch Exchange, and Settings; no domain mutation | empty |
| Today | Companion menu, task route, or memory return; back to Home | Query at most one recommendation plus two secondary tasks | loading, empty, denied, stale, offline, invalid Mock, sync waiting |
| Task | Today; back to Today | Read task; explicit confirmation enters the reducer; automatic completion is display-only | loading, empty, offline, invalid Mock, sync waiting, missing ID |
| Daily Memory | Today or memory notification; returns to source | Read one sealed PS memory; Watch never saves a competing fallback | loading, empty, partial, stale, offline, invalid Mock, sync waiting, missing ID |
| Letters | Companion menu; back to Home | Query profile-scoped `LetterRecord` values | loading, empty, offline, invalid Mock, sync waiting |
| Letter | Letters or notification; returns to Letters | Read, mark read, or explicitly delete one letter; no reward | loading, offline, invalid Mock, sync waiting, destructive, missing ID |
| Touch Exchange | Companion menu; leave or cancel to Home | Preserve the existing privacy-first state machine; use GCS sharing, local DLS capability, and real or isolated Mock SS | loading, empty, denied, offline, invalid Mock, sync waiting |
| Settings | Companion menu; back to Home | Navigation hub for preferences and local capability information; no manual synchronization | loading, offline, invalid Mock, sync waiting |
| Data And Permissions | Settings; back to Settings | Read local DLS capability and link to OS recovery where supported | loading, denied, stale, offline, invalid Mock |
| Data Mode | Settings; back to Settings | Select active profile through a revised GSP value; clear old-profile route state | loading, offline, invalid Mock, sync waiting, destructive |
| Mock Scenario | Data Mode; back to Data Mode | Create and deterministically seed a new Mock epoch | loading, empty, offline, invalid Mock, sync waiting, destructive |
| Reset Mock confirmation | Data Mode in Debug Mock mode | Delete and reseed only the selected Mock profile | offline, invalid Mock, sync waiting, destructive |
| Notification resolver | Local notification response or cold launch | Validate version, profile, epoch, kind, and object ID, then navigate | loading, offline, invalid Mock, missing ID |

The Touch Exchange state machine remains:

```text
idle -> joining -> approaching -> preview -> awaitingPeer -> completed
```

Cancellation, failure, and uncertain cancellation remain first-class states.

## iPhone Route Map

| Route / presentation | Entry and return | Authoritative responsibility | Required states |
| --- | --- | --- | --- |
| Launch | App start; resolves onboarding, selected tab, and saved paths | Load GSP, GCS, DLS, active PS, and route snapshots | loading, invalid Mock, missing route |
| Onboarding | First use or deletion; completes to Mori | Save local presentation state and explicit versioned disclosures; delay optional permissions | loading, offline, invalid Mock |
| Mori tab | Default root, tab, or safe notification fallback | Conversation, approved memory references, and Mori scene; never tasks or coin balance | loading, empty, partial/denied, stale, offline, invalid Mock, sync waiting |
| Task proposal | Valid Chat candidate; dismisses to Mori | Treat model output as untrusted; ask the rule engine whether one task may be issued | loading, offline, invalid Mock, missing proposal |
| Today tab | Tab root | One recommendation, at most three secondary tasks, completed count, and today's memory | loading, empty, partial/denied, stale, offline, invalid Mock, sync waiting |
| Task | Today; back to Today | Explicit confirmation enters reducer; settlement remains idempotent | loading, empty, offline, invalid Mock, sync waiting, missing ID |
| Memories tab | Tab root | Query structured shared memories in reverse chronology | loading, empty, partial/denied, stale, offline, invalid Mock, sync waiting |
| Memory | Timeline, Today, Chat reference, or notification; returns to source | Read sealed memory; deletion is a separate confirmed action | loading, empty, partial, stale, offline, invalid Mock, sync waiting, destructive, missing ID |
| Collection tab | Tab root | Query coin balance and owned, locked, unlocked, and equipped cosmetics | loading, empty, offline, invalid Mock, sync waiting |
| Collection Item | Collection; back to Collection | Preview only until an explicit purchase or equip reducer action | loading, empty, offline, invalid Mock, sync waiting, missing ID |
| Purchase | Collection item; dismisses to item | Atomically write ownership and spend transaction; duplicate submission settles once | loading, offline, invalid Mock, sync waiting, missing ID |
| Letter | Mori or notification; returns to Mori | Read, mark read, or explicitly delete one letter | loading, offline, invalid Mock, sync waiting, destructive, missing ID |
| Settings | Gear from any tab; returns to original tab and path | Navigation hub for GSP, GCS, DLS, PS, and SS management | loading, offline, invalid Mock, sync waiting |
| Companion Settings | Settings; back to Settings | Write companion sensing, reminder mode, and quiet hours; update local adapters immediately | loading, denied, offline, invalid Mock, sync waiting |
| Data And Permissions | Settings; back to Settings | Show DLS health, location, motion, notification, and background capabilities | loading, empty, denied, stale, offline, invalid Mock |
| Conversation Settings | Settings; back to Settings | Control retention and approved memory context; clear only conversation when requested | loading, empty, offline, invalid Mock, sync waiting, destructive |
| Data Mode | Settings; back to Settings | Select real or Debug Mock profile and explain strict isolation | loading, offline, invalid Mock, sync waiting, destructive |
| Mock Scenario | Data Mode; back to Data Mode | Create and seed one new Mock epoch | loading, empty, offline, invalid Mock, sync waiting, destructive |
| Reset Mock | Data Mode in Debug Mock mode | Delete outbox, cache, and state for selected Mock epoch, then reseed | offline, invalid Mock, sync waiting, destructive |
| Friend Sharing | Settings; back to Settings | Write restrictive GCS sharing/publication consent, read DLS Nearby capability, and mutate SS only through the selected real or isolated Mock adapter | loading, empty, denied, offline, invalid Mock, sync waiting |
| Delete All Mori Data | Settings destructive section; completes to onboarding | Execute the global deletion contract and increment its deletion epoch | loading, offline, invalid Mock, sync waiting, destructive |
| Notification resolver | Local notification response or cold launch | Validate route and navigate only; never settle state | loading, offline, invalid Mock, missing ID |

## Notification Contract

Routes are versioned and use stable IDs:

| Route | Required payload | Watch | iPhone | Safe fallback |
| --- | --- | --- | --- | --- |
| `mori/v1/daily-memory` | `memoryID`, `profileID`, `profileEpoch` | Daily Memory | Memories then Memory | Memory root without fabricated content |
| `mori/v1/letter` | `letterID`, `profileID`, `profileEpoch` | Letters then Letter | Mori then Letter | Letters or Mori root |
| Unknown or damaged | none | Home | Current tab or Mori | Ignore and log a redacted diagnostic |

The passive event bubble has no notification deep link. It is a single pending
foreground presentation, not a hidden notification queue.

The current Goal does not schedule task notifications. Tasks are opened from
Today or Mori conversation. A future task-reminder route requires a separate
consent and scheduler-authority decision.

For one compatibility version:

- `pet/recovery` and `pet/care` may navigate to Letters, but cannot synthesize a
  fixed letter;
- `pet/activity` may navigate to Today, but cannot create or finish a task;
- sensitive unknown routes continue to be rejected.

## Cross-Surface State Matrix

| State | Apple Watch | iPhone | Invariant |
| --- | --- | --- | --- |
| Loading | Full-screen only during launch; after Home, preserve scene and use local placeholders | Launch may block; tab content uses shape-matched placeholders without destroying paths | Loading never requests permission or changes domain state |
| Ready | Render only the Home scene or destination content owned by the current route | Render the selected tab/path without a global dashboard wrapper | Ready state comes from a query projection and does not grant mutation authority to the view |
| Empty | Keep Mori on Home; Today and Letters use native empty views; unsaved memory says `正在整理` | Conversation, Today, Memories, and Collection use semantic empty states | Empty is not failure and never creates fake content |
| Permission not requested | Show known facts only; Settings offers an explicit request | Data And Permissions explains and requests on user action | Launch and onboarding never auto-prompt |
| Partial permission | Render only known fresh facts and avoid global health conclusions | Missing facts remain local; other product features continue | Capability belongs to the current device and is not synced as permission |
| Denied or revoked | Home remains neutral; Settings explains recovery | Settings links to OS recovery and does not repeatedly prompt | No penalty, lost coin, or blocked companionship |
| Stale | Do not call old sleep `昨晚`; fresh facts may remain | Exclude old facts from current summaries; sealed memories remain unchanged | Stale is neither zero nor current Chat context |
| Offline | Use local PS; enqueue durable work; Touch Exchange reports retryable failure | Use local fallback; reducers stay idempotent and enqueue synchronization | No manual sync, sync test, or simulated failure control |
| Sync waiting | No Home sync UI; detail may say `等待 iPhone` | Relevant detail may say `已保存，等待 Watch` | Retrying one transaction cannot duplicate it |
| Invalid Mock | Keep navigation to Data Mode reachable, display a persistent Mock error, and construct no real adapter | Preserve tab chrome, fail closed, and keep Data Mode reachable | Never fall back to the real profile |
| Valid Mock | Persistently disclose Mock; use deterministic adapters | All product writes target the selected Mock PS | Profile store, ledger, outbox, and cache remain isolated |
| Missing or deleted ID | Return to the parent route with `内容已不存在` | Return to the owning tab root | Do not restore from an obsolete payload |
| Profile switch | Clear old-profile paths and presentations; return Home | Clear old-profile paths in every tab while retaining selected tab root | Every resolution validates profile and epoch |
| Reset Mock | Confirm and remain in Data Mode | Confirm and remain in Data Mode | Only the selected Mock changes |
| Delete all data | Watch does not initiate global deletion; it honors a newer deletion epoch | Strong confirmation, clear route state, return to onboarding | Follow the global deletion contract and retain the marker until peers/processors acknowledge |
| Unknown deep link | Home | Current tab or Mori | Never mutate authoritative state |
| Notification during onboarding | Stay in onboarding; do not retain an unbounded deferred queue | Stay in onboarding | Durable content remains discoverable at its normal destination |
| Foreground event replacement | New pending event replaces old; presentation consumes once | Persisted consequence appears in Today or Memories, not a duplicate bubble queue | At most one pending event |

## Legacy Navigation Migration

| Legacy surface | Rebuilt destination |
| --- | --- |
| Watch card dashboard | Replace with full-bleed passive Home |
| Watch Trends | Remove from Watch navigation |
| Watch Explanation | Settings > Data And Permissions |
| Watch Messages | Letters backed by `LetterRecord` |
| Watch Touch Exchange | Preserve the state machine; move entry to companion menu |
| Watch pet introduction phase | Merge into onboarding |
| Home data-source picker | Settings > Data Mode |
| iPhone Overview | Mori scene and conversation |
| iPhone History | Structured Memories timeline |
| iPhone Wardrobe | Collection, purchase, ownership, and equip |
| iPhone Privacy tab | Settings subroutes |
| Health-sharing scope | Remove unless a concrete consumer is separately accepted |
| Fixed notification pages | ID-driven task, letter, or memory route |
| Giant root stores | Lifecycle, router, and use-case injection only |

## Contract Tests

- Round-trip encode and decode every route with representative profile, epoch,
  and object IDs.
- Reject wrong profile, old epoch, missing object, unknown version, and
  malformed notification payload.
- Prove notification opening never completes a task or settles a coin.
- Prove Settings dismissal restores the iPhone source tab and path.
- Prove profile switch and deletion clear unsafe paths.
- Prove a purchase, completion, clear, delete, or reset sheet opened before a
  profile/epoch change cannot mutate the new active profile.
- Snapshot each state row at the feature that owns it; do not create one
  dashboard-style global error screen.
