# Product Rules

This document is the product contract. Code, content, and AI prompts must conform to it. Material changes require an ADR and updated tests.

## Product definition

Watch Companion is a Watch-first relationship with a pet that helps a user maintain a sustainable state through recovery, activity, rhythm, and connection. It is a game and companion, not a medical device, clinical monitor, productivity enforcer, or health-score leaderboard.

## Surface rules

- Apple Watch is the primary place for the pet, short habits, story, notifications, and social responses.
- iPhone is a simple management, history, privacy, collection, and cosmetic wardrobe surface.
- Clothing is cosmetic and may unlock presentation or dialogue, never numeric health or competitive advantage.
- There is no desktop or physical-display roadmap in this product.
- Rings and NFC are out of scope.

## Home experience

The Watch home shows:

1. the pet's current state;
2. one sentence about what is happening;
3. one most relevant action.

It does not default to a dashboard of heart rate, sleep, steps, and experience. Users can inspect the source and reasoning behind a suggestion from a secondary view.

## Growth model

Growth has three independent lines:

| Line | Meaning | Primary sources | Guardrails |
|---|---|---|---|
| Vitality | Sustainable physical context | recovery and activity trends | soft daily caps; poor health never subtracts existing growth |
| Bond | Relationship and responsibility | meaningful interaction, explicit commitments, repair | repeated taps or generated chatter do not farm points |
| World experience | Life and shared discoveries | new activities, side stories, social stories | deduplication, cooldowns, one-time memories |

Rules calculate growth. Rewards use caps and diminishing returns; AI may only narrate the result.

## Theme model

Four long-running themes coexist:

- **Recovery:** sleep opportunity, wind-down, micro-rest, wake transition, post-workout downshift.
- **Activity:** walking, workouts, outdoor movement, and trying new activities.
- **Rhythm:** controllable routines, transitions, and explicit commitments.
- **Connection:** pet companionship, trusted care signals, shared stories, and cooperation.

The system observes all themes but normally presents only the most relevant theme and at most one low-pressure opportunity side quest per day. Random events obey independent cooldown and budget rules.

## Story model

- **Main story:** everyone receives the same key chapters in the same order. Health results never gate access.
- **Theme stories:** long-running recovery, activity, rhythm, and connection arcs.
- **Daily side stories:** repeatable, low-impact experiments and habits.
- **Random side stories:** become eligible through specific events, then pass probability, deduplication, prerequisite, and cooldown rules.

For example, a saved soccer workout can make a football story eligible if minimum duration, freshness, cooldown, and completion rules pass. If no workout was recorded, the system must not claim the user played soccer based on heart rate or steps alone.

Randomness decides whether and when an eligible side story appears. It never invents a world fact, changes the main-story sequence, or calculates a reward.

### Phase 1 playable loop

- The shared launch story contains seven ordered beats. A user may complete at most one new beat
  per local calendar day, and each accepted beat awards 10 world-experience points exactly once.
- The Watch presents one theme-appropriate daily opportunity. Completing it awards vitality once
  per local calendar day; repeating or relaunching cannot farm the reward.
- The first random side story, `lost_ball`, is eligible only when HealthKit contains an explicit,
  fresh, read-authorized soccer workout lasting at least 20 minutes. Steps, heart rate, or an
  inferred activity never satisfy this prerequisite.
- Eligibility does not guarantee appearance. A stable seed derived from the workout, day, and
  story identifier performs the probability check, so refresh and replay cannot reroll the result.
- The story and reward events are appended to the versioned ledger before the UI reports success.
  A failed write is not shown as a completed action.

## Responsibility and consequences

There are two kinds of task:

- **Opportunity:** appears automatically; completion earns a reward; expiry causes no loss.
- **Commitment:** exists only after the user explicitly accepts a controllable action.

Health outcomes such as sleeping eight hours may be optional reward quests but cannot create punishment. A user may commit to beginning a wind-down routine, but not to falling asleep, reaching a heart-rate result, or feeling restored.

An unfulfilled commitment has a real, repairable story or relationship consequence:

- the pet remembers the agreement;
- the next relevant conversation acknowledges it;
- the user may explain, resize, renew, repair, or release the commitment;
- existing growth is not removed;
- the pet is not harmed, sickened, killed, or permanently lost;
- content is not permanently locked.

### Phase 2 responsibility foundation

- The only supported commitment kinds are beginning wind-down, taking a micro-rest, taking a
  short walk, and checking in with Mori. They describe actions under the user's control.
- Acceptance is explicit, records the user's local target day and rule version, and allows only
  one unresolved commitment at a time. Acceptance itself grants no reward.
- Fulfilling an active commitment no later than its target day grants 3 bond once.
- After the target day, the commitment must first become `needsRepair`; this removes no growth.
  Repair grants 1 bond once, resizing chooses a new non-past target without reward, and release
  closes the agreement without reward or punishment.
- Invalid time zones, unknown rule versions, duplicate identities, and illegal transitions fail
  closed. The current implementation is a tested domain foundation and has no shipped UI yet.

## Initiative and notification authority

```text
Rule engine: may an interaction occur?
Seeded scheduler: when among allowed windows might it occur?
Narration: how does the pet express it?
```

Quiet hours, active rest, frequency caps, cooldowns, stale-data checks, and user notification settings outrank story urgency. The pet can remain quiet; silence is a valid companion behavior. AI cannot schedule or send a notification directly.

For the current local-notification slice, the seeded scheduler chooses a replay-stable whole-minute
delay between 10 and 90 minutes from the latest approved state. Different event histories can lead
to different times. This changes timing only: policy may still suppress the interaction, and
reopening or replaying the same state cannot reroll it.

## Health interpretation

- Compare with the user's own baseline where possible; do not use a universal target as diagnosis.
- Explain observations and uncertainty, not disease or risk.
- Ask for context and suggest small controllable experiments.
- Do not promise that one habit caused an improvement.
- Short term rewards trying or willingly repeating a habit; medium term observes trends; long term helps the user understand a sustainable pattern.
- No data, stale data, and denied access are neutral system states.

## Social privacy

Friendship requires mutual confirmation. Health-sharing scope is independently controlled by the person whose data produces the signal; A's setting for B does not grant B's data to A.

The default after one-time informed enablement is **care summary**:

- may express a vague need for support or quiet;
- does not reveal sleep, heart rate, activity, dates, durations, values, source categories, or medical labels;
- is not emitted for every underlying change, to reduce inference;
- offers low-pressure actions such as a small gift, quiet message, or help with a shared task.

Other owner-controlled scopes:

- **Game state only:** no health-derived social signal.
- **Limited health summary:** may name a broad trend such as reduced recent sleep, but precise values remain excluded by default.

Removing a friend or disabling sharing immediately revokes future access. Relationship gameplay uses one friendship model with optional cooperative or mutually accepted competitive activities; it does not assign permanent labels such as partner or rival.

Competition must not reward sleep deprivation, excessive exercise, absolute heart rate, or raw step totals. Compare voluntary progress toward personal goals when competition is added.

## AI authority

AI may:

- express an already approved observation;
- adapt tone to stable pet personality and relationship history;
- add bounded color within an approved story node;
- offer choices that the rule engine has declared legal.

AI may not:

- diagnose, prescribe, or call health data abnormal;
- modify growth, inventory, quests, commitments, story facts, friendships, or permissions;
- schedule notifications or bypass safety policy;
- expose hidden health context to a friend;
- invent sensor observations or claim causal health benefit;
- act as another user.

When AI is unavailable or invalid, local templates preserve the complete flow.
