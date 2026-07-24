# Physical Device Runbook

## Purpose

Use this runbook to separate verified Apple Watch behavior from simulator, fixture, or design assumptions. Execute only with test accounts and synthetic/non-sensitive notes. Do not commit device logs or health exports.

## Evidence header

Record for every run:

```text
Git revision:
Build configuration:
iPhone model / OS:
Apple Watch model / OS:
Developer account type:
Time zone:
Permission state:
Fixture or real data:
Tester:
```

Redact serial numbers, account identifiers, health values, tokens, and notifications before sharing evidence.

## 1. Installation and connectivity baseline

1. Pair the test Watch with the test iPhone.
2. Install a clean build through Xcode.
3. Launch both apps and verify version/schema agreement.
4. Disable connectivity, perform one Watch action and one iPhone wardrobe action, then reconnect.
5. Verify queued events settle once, no reward duplicates, and the most recent valid wardrobe revision wins.

Pass requires deterministic final state after two repeated runs.

## 2. HealthKit capability spike

Test each permission state independently:

1. not requested;
2. requested with available types;
3. partial/empty history;
4. permission changed in Settings;
5. multiple compatible data sources;
6. stale data;
7. a newly completed supported workout.

Verify source, time zone, freshness, units, deduplication, anchor persistence across relaunch, and neutral no-data UI. Run three cold-start reads. For workouts, run at least three five-minute sessions and confirm that repeated ingestion does not repeat rewards.

Background delivery timing must be recorded as observed, never promised as immediate.

## 3. Local notification and haptic spike

1. Verify first-request explanation and system prompt.
2. Schedule a short, non-sensitive local event.
3. Test delivery with Watch app foreground, background, terminated, and under a Focus mode.
4. Open the notification and verify the intended route.
5. Reopen it and verify no duplicate task completion or reward.
6. Deny permission and verify a usable in-app path without repeated prompting.
7. Evaluate each haptic on a real Watch; simulator execution is insufficient.

Pass requires five consecutive notification-route runs without duplicate settlement. Do not promise delivery timing when Focus or system scheduling may intervene.

## 4. Smart alarm spike

This capability is used only for a genuine user-scheduled wake flow.

1. Schedule the permitted future wake window while the app is active.
2. Verify cancellation and rescheduling.
3. First run three short daytime sessions and observe background lifecycle callbacks.
4. Test motion/heart-rate availability and resource-limit behavior without logging raw values.
5. Complete at least one real sleep-window test.
6. Verify the latest-time fallback always fires even when no preferred wake opportunity is selected.
7. Test app relaunch, Watch restart, missed session, low-power conditions, and denied health access.

Pass requires three successful short runs, one real sleep run, no resource-limit termination, and a reliable fallback. Until then the shipped behavior is fixed local alarm plus post-wake summary, and the capability is labeled unverified.

Do not claim precise real-time sleep-stage detection. Describe the feature as a bounded flexible wake window using available motion and heart-rate context.

## 5. Nearby Interaction spike

This test is independent of Phase 1 and requires two compatible physical Apple Watches and two test identities.

1. Both users explicitly enter the proximity flow.
2. Verify friend sharing is enabled on both paired iPhones, then tap `开始触碰` on both Watches;
   there is no user-entered pairing code.
3. Verify the HTTPS discovery service exchanges only temporary discovery tokens before proximity.
4. Validate expiration, replay protection, cancellation, candidate timeout/retry, and
   multiple-candidate handling.
   Confirm delayed requests from an expired candidate are rejected by encounter ID and nonce.
5. Test approaching, separating, foreground interruption, permission denial, and `nil` distance.
6. Require a stable threshold for multiple samples, then show a preview.
7. Require confirmation on both Watches before creating an encounter.
8. Place Watch A physically to the left of Watch B. Confirm that the pet on A starts after the
   same countdown as B, exits A's right edge, enters B's left edge, lands once, and is not replayed
   by status refresh or relaunch. Repeat with the other character. Record both screens in one shot
   when possible; the framework does not report physical left/right placement.
9. Enable Reduce Motion on both Watches and verify the travel becomes a bounded cross-fade.
   Delay one client past the scheduled end and verify its short landing fallback completes once.
10. Interrupt a cancel request and verify the Watch reports an unconfirmed cancellation, retries
   cleanup, and does not start a new session first.
11. Repeat at least twenty times in representative environments.

Target: at least eighteen of twenty sessions identify proximity within ten seconds, with zero incorrect or duplicate friendship creation. Treat this as a product target, not a guarantee of the framework.

Nearby Interaction supplies proximity context only. It does not discover peers, transfer pet data,
establish identity, or replace bilateral consent. The app's service performs candidate discovery,
and the UWB result gates preview and confirmation. If unverified, do not advertise physical
tap-to-connect reliability.

## 6. Phase 1 product journey

On real devices:

1. Clean install and complete only the permissions needed by the current feature.
2. Load current health context or remain in the neutral state.
3. Observe one rule-selected recovery/activity action.
4. Complete it and inspect the explanation and growth result.
5. Relaunch both apps and confirm persistence.
6. Record a supported workout and validate one-time ingestion.
7. Change a cosmetic on iPhone and verify Watch synchronization.
8. Disable network/AI and repeat the core flow with local narration.

Repeat the primary loop ten times without inconsistent or duplicate state.

## Result classification

- **PASS:** observed evidence satisfies every stated criterion on the recorded devices.
- **FAIL:** observed evidence contradicts a criterion; document fallback and issue.
- **UNVERIFIED:** required hardware, account capability, time window, or evidence is missing.

Mocks and simulator tests may accompany a device result, but cannot upgrade `UNVERIFIED` to `PASS`.
