# Mori Rebuild Test Matrix

- Status: Frozen test ownership
- Date: 2026-07-24

This matrix assigns each product invariant to the Goal that owns its
implementation. G0 freezes the cases and evidence format. Unit, integration,
static, Simulator UI, and Computer Use cases become required PASS when their
owning Goal reaches its implementation gate. A physical `Device` case is tracked
on the independent device axis: when the audited setup is unavailable it remains
`UNVERIFIED`, does not block `IMPLEMENTATION_COMPLETE`, and blocks
`DEVICE_VALIDATED` and `RELEASE_READY`.

## Evidence Levels

- `Unit`: pure values, reducers, policies, codecs, and migrations.
- `Integration`: repository, adapter boundary, persistence, and transport.
- `UI`: deterministic XCTest behavior on iPhone or Watch Simulator.
- `CU`: visible journey verified with Computer Use after UI automation.
- `Device`: physical hardware evidence; Simulator cannot satisfy it.
- `Static`: repository search, binary scan, schema validation, or asset QA.

## G0 — Contract And Baseline

| Case | Evidence | Current disposition |
| --- | --- | --- |
| Release binary excludes fixtures, launch selectors, and Mock identifiers | Static + Release tests | PASS at `e4265fe` |
| Debug iPhone and Watch retain deterministic Mock selection | Unit + UI | Unit PASS; current iPhone and Watch default-selection UI PASS |
| Existing packages and app smoke tests build | Unit + integration | PASS at `e4265fe` |
| Current iPhone E2E behavior is recorded without hiding historical failures | UI | 5/10 PASS; exact five failures recorded in status |
| Current Watch E2E behavior is recorded | UI | Standalone 15/18 PASS; exact three failures and result bundle recorded in status |
| Existing accessibility baseline is recorded | UI + Static | iPhone contrast and Watch accessibility-audit failures recorded; dedicated suite pending |
| Approved design references are repository-owned | Static + visual review | Added under approved reference directory |
| Route, state, ADR, capability, and test contracts are complete | Review | Required before G0 commit |
| Global deletion inventory covers every local, peer, notification, and processor store | Review | Required before G0 commit |

## G1 — Authoritative Domain

| Behavior | Primary evidence |
| --- | --- |
| One real event creates zero or one task | Unit, property |
| Every profile record carries profile/deletion epoch; every passive event also carries sensing epoch | Codec + unit + negative property |
| Same-type cooldown survives restart, midnight, time-zone/DST change, and clock rollback | Unit, property |
| Reliable task auto-completes; uncertain task requires explicit confirmation | Unit |
| Auto and manual completion race settles one reward | Unit, property |
| Coin tiers are integer `1`, `2`, `4`, and rare `6...10`; no daily cap | Unit |
| Earn, spend, replay, reversal, and concurrent purchase preserve a non-negative balance | Unit, property |
| Memory has deterministic profile/day/time-zone identity and seals once | Unit, property |
| Low confidence remains silent; missing/denied/stale data is neutral | Unit |
| Letters converge across read, delete, duplicate, offline, and relaunch | Unit, property |
| Chat candidate cannot mutate tasks, coins, collection, permission, or memory | Unit, negative |
| Legacy reset removes level, XP, vitality, bond, insight, trends, and fixed story exactly once | Unit, migration |
| Legacy progression never converts to coins | Unit, migration |

Required property baseline: at least 1,000 deterministic timeline seeds.

## G2 — Evidence And Profile Runtime

| Behavior | Primary evidence |
| --- | --- |
| Health, motion, coarse location, activation, and interaction normalize behind protocols | Unit + integration |
| Turning `Mori 随行` off stops adapters, clears pending reminders, and creates no passive output | Integration + UI |
| Re-enable never backfills the disabled interval | Unit + integration |
| Offline peer events from a superseded sensing epoch are rejected | Integration |
| Exact/high/medium/low confidence maps to direct/natural/tentative/silent copy | Unit |
| Real and Mock never share tasks, coins, memories, letters, conversation, collection, ledger, outbox, or cache | Integration, property |
| Invalid/valid Mock never constructs real health, location, motion, notification, Chat, narration, connectivity, or social adapters | Integration + UI |
| Scenario change creates and seeds only one new Mock epoch | Integration + UI |
| Reset selected Mock leaves real state byte-for-byte unchanged | Integration |
| Raw health samples and precise routes never enter logs, sync, memory, or Chat | Static + negative integration |

Physical sensor availability remains a Device gate, not a Simulator assertion.

## G3 — Sync, Reminder, And Daily Memory

| Behavior | Primary evidence |
| --- | --- |
| Global preferences converge by logical revision and stable origin ID | Unit, property, integration |
| GCS revocation wins immediately; concurrent consent merges most-restrictive and only iPhone may expand remote/notification consent | Unit, property, integration |
| Device permission is never synchronized as peer authorization | Unit + integration |
| Duplicate, reordered, delayed, and retried experience envelopes converge | Property + integration |
| Profile/epoch mismatch fails closed | Unit + integration |
| Offline task completion and coin settlement merge once | Integration + UI |
| Profile-scoped Mori identity, cosmetic purchase, and equip converge across peers without crossing real/Mock epochs | Integration + cross-device UI |
| Memory deletion tombstone removes the peer record, notification route, and future Chat context | Integration + cross-device UI |
| Conversation messages/summaries never enter Watch transport; only approved memory references may converge | Static + negative integration |
| Social relationship/public-card state never appears in an experience envelope | Static + negative integration |
| Pending event presents once on the next eligible activation | Unit + Watch UI |
| Pending event expires at two minutes or is replaced by one newer event; no queue grows | Unit + Watch UI |
| Quiet hours suppress haptic/notification according to reminder mode | Unit + UI; Device for physical behavior |
| iPhone alone schedules paired daily-memory notification | Integration + UI |
| Daily-memory and letter scheduling require GCS opt-in plus local OS authorization and obey stable IDs, quiet hours, per-kind cooldown, total budget, and cancellation | Integration + UI |
| Letter delivery/read/delete converges and cancels an obsolete pending notification | Integration + cross-device UI |
| Watch renders the synced sealed memory and cannot persist a competing fallback | Integration + Watch UI |
| Opening any notification only navigates | Unit + UI |
| Late evidence never duplicates or silently rewrites sealed memory | Unit, property |
| Delete marker prevents an offline peer from restoring old state | Integration |

## G4 — Complete Mori Motion

| Behavior | Primary evidence |
| --- | --- |
| Black penguin and white polar bear have semantic parity without recolor identity drift | Static + visual review |
| Foundation atlases preserve approved 8×11 and 16-direction behavior | Asset validator + contact sheets |
| Dedicated clips replace invalid emotional aliases | Static + visual review |
| Every action declares trigger, interruption, return, Reduce Motion, priority, and surface | Catalog tests |
| Missing or invalid catalog entry falls back to neutral idle | Unit + UI |
| No crop, seam, baseline jump, detached effect, contamination, or reversed gait | Asset validator + visual review |
| Motion reads within roughly 300–500 ms at Watch size | Image2 review + Simulator CU |
| Watch runtime exports only required frames and stays within memory budget | Static + performance |
| Cosmetics use one bounded scalable strategy | Architecture review + asset tests |

Physical frame pacing, thermal, battery, and haptic feel remain Device gates.

## G5 — Apple Watch Experience

| Journey | Primary evidence |
| --- | --- |
| Home is full-bleed with Mori, sleep upper-left, steps lower-right, and companion entry only | Watch UI + CU |
| Home contains no levels, vitality, XP, cards, task list, trends, coin, or sync control | Static + Watch UI + CU |
| Mori tap response and long-press menu do not conflict or repeat | Watch UI + CU |
| Long press has VoiceOver and visible alternatives | Accessibility UI + CU |
| Companion quick settings change sensing, reminder mode, and quiet hours | Watch UI + integration |
| Event bubble presents briefly, consumes once, expires, and is replaced | Watch UI |
| Today shows one recommendation and at most two secondary tasks | Watch UI + CU |
| Automatic and manual task semantics are clear | Watch UI + CU |
| Daily Memory shows relationship prose with facts secondary | Watch UI + Image2 + CU |
| Letters preserve read, unread, deletion, empty, and offline state | Watch UI |
| Touch Exchange preserves the full cancellation/failure state machine | Watch UI |
| Data Mode and Mock reset remain reachable from Settings | Watch UI |
| 40 mm and largest supported display, Dynamic Type, Reduce Motion, high contrast, VoiceOver, and no-haptic mode pass | Accessibility UI + CU |
| Relaunch, notification route, profile switch, and missing ID restore safely | Watch UI |

## G6 — iPhone Experience

| Journey | Primary evidence |
| --- | --- |
| Root tabs are Mori, Today, Memories, and Collection; gear opens Settings | iPhone UI + CU |
| Mori is conversation and presence with no tasks or coin balance | Static + iPhone UI + CU |
| Mori conversation renders sending, streaming, cancellation, offline fallback, retry, malformed/oversize failure, clear-history, and context-consent states from G7 | iPhone UI + CU |
| Today shows one recommendation and at most three secondary tasks | iPhone UI + CU |
| Memories read as shared life rather than exercise history | Image2 + iPhone UI + CU |
| Collection covers balance, owned, locked, preview, purchase, equip, insufficient balance, and offline | iPhone UI + integration + CU |
| Purchase and retry settle once and survive relaunch | Integration + iPhone UI |
| Settings holds companion, permissions, conversation, Data Mode, Mock, sharing, and deletion | iPhone UI + CU |
| There is no manual synchronization, sync-test, or failure-simulation product control | Static + UI |
| Clear conversation preserves memories; the global deletion transaction clears every governed store or reports pending processors honestly | Integration + iPhone UI |
| Settings closes to the original tab/path | iPhone UI |
| Profile/epoch switch invalidates an already-open task, purchase, clear, delete, or reset confirmation before reducer mutation | Unit + iPhone UI |
| Every tab covers its owned loading, empty, offline, invalid-Mock, and sync-waiting states; Mori/Today/Memories and Data And Permissions cover applicable partial, denied, and stale facts; Collection does not invent health states | iPhone UI |
| Light/dark, Dynamic Type, Reduce Motion, high contrast, VoiceOver, and Switch Control pass | Accessibility UI + CU |

## G7 — Mori Conversation

| Behavior | Primary evidence |
| --- | --- |
| Request distinguishes explicitly sent user text from separately consented allowlisted app context | Contract + negative integration |
| App context rejects raw health, precise location, hidden confidence, contacts, and secrets; the user-text scanner blocks recognized credentials and warns without claiming perfect DLP | Contract + negative integration |
| Model cannot invoke state-changing tools | Contract + adversarial |
| Invented facts, diagnoses, reward grants, permission changes, and cooldown bypass are rejected | Adversarial |
| Candidate task is revalidated locally and may become at most one legal task | Unit + integration |
| Timeout, malformed response, rate limit, server failure, and offline produce calm headless presentation state for G6 | Integration + presentation-model unit |
| Retention, clear history, profile isolation, and the global deletion transaction behave correctly | Integration |
| Memory-context revocation and memory deletion invalidate all future prompt indexes and excerpts | Integration |
| Remote Chat includes at most one separately consented memory excerpt of 500 Unicode scalars | Contract + negative integration |
| Logs contain request ID and redacted error class, not message content | Static + integration |

## G8 — End-To-End Product Loops

| Loop | Primary evidence |
| --- | --- |
| Passive evidence -> Mori action -> optional task -> one reward -> memory | Cross-device E2E + CU |
| New event replaces old pending reminder and appears once | Watch E2E + CU |
| iPhone schedules and Watch opens the same daily memory | Cross-device E2E |
| Offline issue/complete/reconnect converges tasks and coins once | Cross-device E2E |
| Preference conflict, scenario conflict, and profile epoch converge | Cross-device E2E |
| Invalid Mock and reset never touch real state | Cross-device E2E |
| Delete all prevents stale peer resurrection | Cross-device E2E |
| Delete all clears Chat summary/context, notifications, social processors, routes, and every real/Mock profile or reports a pending processor honestly | Integration + cross-device E2E |
| Deletion-scoped retry ticket survives content clearing, and fresh-install fence-first handshake rejects an offline pre-deletion Watch epoch | Integration + cross-device E2E |
| Daily-memory and letter notification routes survive cold launch, onboarding, profile switch, missing object, and old version | Cross-device E2E |
| Touch Exchange transfers only explicitly approved social data | Device E2E; separate device axis |

## G9 — Release And Open-Source Quality

| Gate | Evidence |
| --- | --- |
| All package, app, E2E, accessibility, release-boundary, and visual-asset tests pass | CI + local release candidate |
| No fixture, test selector, Mock identifier, secret, raw health, or precise route appears in Release artifacts or logs | Static + binary scan |
| Formatting, lint, public API docs, license inventory, notices, contribution guide, and reproducible bootstrap pass | Static + clean checkout |
| Static and Simulator performance budgets pass; physical budgets are recorded separately | Performance + Device axis |
| Privacy manifests, entitlements, usage descriptions, deletion, and logging match actual behavior | Audit + Device |
| Independent code, product, accessibility, privacy, and asset review has no unresolved P0/P1 | Review record |

## Evidence Record Format

Every Goal checkpoint records:

- exact Git revision and dirty/clean state;
- exact command or Computer Use journey;
- simulator model, OS, and test result bundle when applicable;
- PASS, FAIL, or UNVERIFIED without translating one into another;
- failing test name and first actionable assertion;
- reviewer, findings, and disposition;
- physical-device identifier class and consent state, but no personal health or
  location content.
