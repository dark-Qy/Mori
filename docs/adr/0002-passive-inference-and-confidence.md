# ADR 0002: Passive inference and confidence

- Status: Accepted
- Date: 2026-07-24

## Context

Mori should feel present while requiring little or no deliberate input. Activity,
sleep, motion, location category, time, and interaction history may suggest what
the person is doing, but most of those suggestions are not facts. Showing an
internal probability or presenting an uncertain interpretation as certain would
turn companionship into a surveillance dashboard and erode trust.

watchOS background execution and wrist activation are also best-effort. The
product cannot promise continuous sampling, an exact event time, or guaranteed
delivery on the next wrist raise.

## Decision

The device produces two different kinds of records:

1. `ObservedFact` contains an approved, minimized fact such as a step count,
   sleep duration, broad motion transition, or arrival at a user-approved place
   category. It records provenance and freshness.
2. `PassiveCompanionEvent` is a local interpretation derived from one or more
   facts. It records an internal confidence band, evidence references, sensing
   epoch, observed time, and policy keys.

Confidence has four product bands:

- exact facts may be stated directly;
- high-confidence interpretations use natural, specific language;
- medium-confidence interpretations use tentative language;
- low-confidence interpretations remain silent.

The UI never shows a numeric confidence value. Mori may say “刚才那段路走得好快”
when the policy threshold is met, but never claims an exact activity that the
available evidence cannot establish.

Each reminder-eligible event has one two-minute presentation eligibility window.
It may be presented once on the next foreground activation, replaced by a newer
event, or expire. The speech bubble itself is brief; it does not remain visible
for two minutes. Reminder lifecycle is independent from durable memory
eligibility.

Turning off `Mori 随行` establishes a new sensing epoch, stops local passive
adapters, clears pending reminders, and prevents new passive tasks or memories.
Re-enabling does not backfill the disabled interval.

## Invariants

- Raw HealthKit samples and precise GPS tracks are not companion events.
- Missing, partial, denied, stale, or unavailable data is neutral.
- A low-confidence inference cannot create a task, reward, notification, or
  memory claim.
- A newer pending event replaces the older event; there is no reminder queue.
- Haptics and notifications obey reminder mode, quiet hours, cooldown, and
  accessibility settings.
- Simulator or Mock evidence never counts as physical capability validation.

## Consequences

Mori may sometimes remain quiet even when the person expects a reaction. That is
an intentional trust tradeoff. Product copy, task generation, daily memory, and
chat context must all consume the same authoritative event rather than making
independent guesses.

## Validation

- Pure policy tests cover confidence bands, tentative copy, silence, expiry, and
  replacement.
- Epoch tests prove disable/re-enable and offline peer reconciliation
  cannot backfill suppressed evidence.
- Simulator tests verify visible fallback states.
- Physical-device tests separately verify attainable sampling and delivery
  behavior without claiming guaranteed background execution.
