# Mori Physical Device Runbook

## Purpose

Use this runbook only for hardware-dependent evidence that Simulator, Mock,
XCTest, and Computer Use cannot prove. It controls the independent
`DEVICE_VALIDATED` and `RELEASE_READY` axes. Missing hardware remains
`UNVERIFIED` and does not become a simulated PASS.

Use dedicated test identities and synthetic or deliberately minimized notes.
Never commit device logs, health exports, precise routes, messages, tokens,
serial numbers, or unsanitized notifications.

## Evidence Header

Record for every run:

```text
Git revision and clean/dirty state:
Build configuration:
iPhone model / OS:
Apple Watch model / OS:
Pairing state:
Signing team class:
Test identity class:
Time zone and Focus state:
App consent revision and opt-ins:
OS HealthKit / location / motion / notification permission state:
Real or deterministic Mock profile:
Tester:
Sanitized evidence path:
```

Every row is `PASS`, `FAIL`, `UNVERIFIED`, or `NOT_APPLICABLE`. Record observed
timing rather than promising immediate background delivery.

## 1. Install, Pair, And Fence Baseline

1. Pair the test Watch with the test iPhone and install the same clean revision.
2. Launch both apps and record schema, profile root epoch, and deletion fence.
3. Verify onboarding does not request HealthKit, location, motion, notification,
   Chat, or sharing permission before the corresponding explanation and action.
4. Switch between real and Debug Mock profiles on both devices and verify
   profile/epoch agreement.
5. Confirm a route or open confirmation from an old profile epoch cannot mutate
   the newly selected profile.
6. Terminate and relaunch both apps twice; confirm stable state and no duplicate
   event or notification scheduling.

Pass requires matching schemas/epochs, no implicit permission request, and no
cross-profile content.

## 2. HealthKit, Location, And Motion

Test each available capability independently:

1. not requested;
2. available and explicitly requested;
3. partial or empty history;
4. denied or revoked in Apple Settings;
5. multiple compatible HealthKit sources;
6. stale evidence;
7. fresh completed sleep, steps, and supported movement evidence;
8. background opportunity, delayed delivery, and app termination.

Verify provenance, time zone, freshness, units, deduplication, anchor
persistence, and neutral missing-data behavior. Mori must not present a global
health conclusion, activity diagnosis, or user-facing confidence percentage.

Raw HealthKit samples, precise fixes/routes, and motion windows remain on device
and are absent from logs, sync envelopes, memories, notifications, Chat, and
support evidence. Background timing is recorded as observed and never described
as continuous or guaranteed.

## 3. Companion Reminder, Haptic, Focus, And Notification

Use current `GlobalConsentState`, current-device OS authorization, and the
configured quiet hours.

1. With `Mori 随行` off, verify adapters stop, pending glance clears, and no
   passive event/task/memory is created or later backfilled.
2. With `抬腕提醒`, create one eligible event and observe the next foreground
   activation. Verify one brief bubble, consumption, two-minute expiry, and
   replacement by a newer event. Do not claim a wrist-raise callback.
3. With `轻震提醒`, verify one comfortable haptic only when the eligible glance
   is actually presented while the Watch runtime can haptically respond.
   Verify no retroactive or background-haptic claim.
4. Repeat in quiet hours, Focus, Low Power Mode, app background, and app
   terminated states. Verify the visual/no-haptic fallback.
5. Opt in separately to daily-memory and Mori-letter notifications. Verify
   scheduling requires app consent and OS authorization.
6. Verify daily memory schedules at most once per local day after 22:00.
7. Verify letter notification has a six-hour cooldown, at most one per day, and
   the combined product budget is at most two notifications per day.
8. Revoke consent, read/delete the letter, switch profile, and execute deletion;
   verify matching pending requests cancel.
9. Open and reopen each delivered notification. It may navigate only and cannot
   create a task, settle a coin, or restore deleted content.

Record physical haptic comfort and suppression separately from route success.

## 4. Offline Sync, Profile Isolation, And Global Deletion

1. Disconnect Watch and iPhone.
2. On Watch, create an approved derived event; on iPhone, perform a
   profile-scoped identity/equip action.
3. Reconnect and verify the complete profile epoch, event ledger, identity, and
   equip state converge once.
4. Complete the same task on both devices while disconnected; reconnect and
   verify one coin settlement.
5. Change companion consent and Mock scenario concurrently; verify the winning
   Lamport epoch and most-restrictive consent, with losing-epoch work discarded.
6. Verify conversation messages/summaries never enter Watch transport.
7. Start `删除所有 Mori 数据` while Watch or an enabled processor is offline.
   Verify the iPhone prepares deletion-scoped tickets/fence before clearing
   content and reports pending peers/processors honestly.
8. Reconnect and verify the deletion epoch is applied before queued content.
9. Uninstall/reinstall iPhone, then reconnect an offline pre-deletion Watch.
   Verify fence-first handshake and no automatic resurrection of old content.

Repeat the disconnect/reconnect sequence twice. No route, outbox, peer snapshot,
notification, Chat index, social callback, or old epoch may restore deleted or
cross-profile state.

## 5. Mori Motion, Accessibility, And Performance

Run the black penguin and white polar bear on the smallest and largest supported
physical Watch:

1. Verify semantic parity for every production action and Reduce Motion key
   frame at actual size.
2. Exercise tap, long press, visible alternative, VoiceOver action, task
   success, speaking, walk, brisk move, sit, catch breath, daily reflection, and
   bedtime transitions.
3. Confirm no crop, baseline jump, body-scale pop, seam, detached effect,
   reversed gait, or identity drift.
4. Verify long press and haptic are never the only access or state cue.
5. Run the scripted foreground scene for 30 minutes. Record frame intervals,
   decoded scene/frame-cache memory, CPU/energy, thermal state, crashes, and
   battery change.
6. Verify inactive and Always On states stop sub-second animation timers and use
   the semantic static frame.

Compare results with the provisional budgets in the Goal plan. If physical
evidence invalidates a budget, update an ADR and implement a downgrade before
claiming device validation.

## 6. Touch Exchange

This requires two compatible physical Apple Watches, paired iPhones, and
dedicated test identities.

1. Confirm friend sharing on both iPhones; disabled sharing must prevent any
   production gateway request.
2. Enter Touch Exchange explicitly on both Watches; there is no pairing code.
3. Before proximity, exchange only temporary discovery material.
4. Test token expiry, nonce/replay rejection, multiple candidates, separation,
   interruption, permission denial, `nil` distance, timeout, and retry.
5. Require stable proximity evidence before showing the allowlisted public pet
   card.
6. Require confirmation on both Watches before creating a relationship.
7. Interrupt cancellation and verify uncertain cleanup blocks a new session
   until resolved.
8. Confirm no health-derived data, memory, free text, conversation, task, coin,
   or sharing preference is transferred.
9. Repeat at least twenty times in representative environments.

The target is at least eighteen of twenty timely proximity identifications with
zero incorrect or duplicate relationship creation. This is a product target,
not a guarantee of Nearby Interaction.

## 7. Primary Mori Journeys

On the same recorded revision:

1. passive evidence -> brief Mori glance -> optional task -> automatic or
   explicit completion -> one coin -> Collection purchase/equip;
2. sealed daily memory -> best-effort notification -> Watch scene -> iPhone
   timeline -> separately consented Chat memory reference/excerpt;
3. permission denial/revocation -> neutral Mori -> Settings recovery -> product
   remains usable;
4. black/white identity switch in Mock, Mock reset, then return to byte-for-byte
   untouched real profile;
5. network/Chat provider unavailable -> calm local conversation fallback with
   identical authoritative state.

Repeat the primary loops without duplicate rewards, ghost tasks, rewritten
sealed memories, missing deletion fences, or raw/private data in evidence.

## Result Classification

- **PASS:** observed hardware evidence satisfies the criterion on the recorded
  revision and setup.
- **FAIL:** evidence contradicts the criterion; record the fallback and issue.
- **UNVERIFIED:** hardware, identity, pairing, signing, permission, time window,
  or evidence is insufficient.
- **NOT_APPLICABLE:** the capability is not configured in the evaluated build;
  state why.

Simulator and Mock evidence may accompany a device result but cannot upgrade
`UNVERIFIED`. `RELEASE_READY` requires all mandatory device rows to PASS on the
same release candidate; `IMPLEMENTATION_COMPLETE` may coexist with
`DEVICE_UNVERIFIED` and `NOT_RELEASE_READY`.
