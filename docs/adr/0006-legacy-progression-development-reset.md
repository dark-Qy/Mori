# ADR 0006: Legacy progression development reset

- Status: Accepted
- Date: 2026-07-24

## Context

The prototype is built around level, XP, vitality, bond, insight, a fixed
seven-day story, health trends, and daily completion. The accepted Mori product
instead uses passive companionship, lightweight tasks, coins, collection, and
shared memories. Renaming old counters would carry the wrong incentives and
make health outcomes look like performance scores.

There are currently no formal users whose production history must be migrated.

## Decision

The rebuild performs one versioned development reset rather than maintaining a
long-lived compatibility layer.

The reset removes:

- level, XP, vitality, bond, and insight balances;
- fixed seven-day main-story progress and completion gates;
- health-score and trend-dashboard projections;
- obsolete daily-habit settlement state;
- string-only story memories that cannot become a valid structured memory.

The reset preserves only independently valid, user-controlled data:

- onboarding completion when its consent version is still current;
- selected Mori identity and supported cosmetic selections;
- reminder choice and quiet hours after validation;
- explicit privacy and sharing choices whose schema remains supported.

Real and Mock stores reset independently. Resetting or reseeding Mock never
touches real state. The reset writes a schema marker so it runs once and remains
idempotent across relaunch and peer reconnection.

No old progression value is converted into coins. No health outcome is used to
seed tasks, rewards, streaks, or penalties.

## User experience

Because the audience is the development team, the reset may occur automatically
on first launch of the rebuilt schema. The app shows a concise development
notice in Developer Options and records the reset version locally. It does not
present a fake user migration success screen.

## Consequences

Existing prototype screenshots and E2E tests that assert level, vitality, fixed
story, or old task copy become historical baseline evidence and are replaced by
new product tests. This deliberately reduces compatibility code and prevents
old semantics from leaking into the new domain.

## Validation

- Migration tests cover empty, valid legacy, malformed, future, repeated,
  real-profile, and Mock-profile stores.
- Relaunch and offline-peer tests prove the reset is idempotent and old events
  cannot restore removed fields.
- Repository searches and UI audits prove no level, XP, vitality, bond, insight,
  health-score, or fixed-story copy remains in production surfaces.
- Coin ledgers begin empty and can only change through the new settlement rules.
