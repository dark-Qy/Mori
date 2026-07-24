# G5 Watch UI Contract

## Scope

G5 replaces the legacy Watch dashboard with a quiet companion surface. The
current implementation is Mock-first and deliberately does not merge the
separate G4 motion branch.

## Information Architecture

### Home

- One full-bleed world with Mori as the primary subject.
- Sleep appears at the upper left and steps at the lower right.
- `Mori 随行中` is the only persistent home control.
- Tapping Mori produces one brief response.
- Long pressing Mori opens `今天`, `Mori 来信`, `碰一碰`, and `设置`.
- The home never displays tasks, levels, XP, vitality, coin balance, health
  scores, trends, synchronization controls, or a card stack.

### Mori Companion

Tapping `Mori 随行中` opens a native Watch list containing:

- companion sensing;
- wrist-raise or gentle-haptic reminder behavior;
- quiet-hours start and end.

An eligible event may appear once on the next foreground activation for at most
two minutes. The newest event replaces an older pending event. Quiet hours
suppress the optional haptic, not the visual result.

Companion sensing, reminder mode, and quiet hours use the durable G3 global
preference schema. The current Watch composition persists local choices across
relaunch. Peer transport composition remains deferred, so this checkpoint does
not claim paired-device convergence. Until the real event adapter is composed,
Release labels Mori Companion as waiting for connection and does not expose
interactive reminder controls; it never simulates production behavior.

### Today

`今天` emphasizes exactly one recommendation. A reliably detected walk may
appear as a compact automatically completed row. Known sleep duration is
presented as a neutral fact, never as a rewarded outcome. The Debug Mock
recommendation is an explicit controllable action with a one-coin reward.
Its isolated preview receipt is durable and at-most-once across relaunch; it is
not presented as the production profile ledger.

### Daily Memory

The Watch daily-memory destination is an immersive night scene. In this
Mock-first checkpoint it labels itself as a preview and renders only exact step
and sleep facts. It never invents a pause, route, or other event. Production
Watch will render a synchronized sealed record and will not author or repair a
missing memory.

### Settings

Settings use native lists. `Mori 随行` is separate from app data status.
Application choices are not described as system authorization; the UI directs
the user to Apple Watch Settings for system permission state.
Debug builds expose isolated data-mode and Mock reset controls. There is no
manual synchronization, synchronization test, or simulated-failure control.

## Mock Harness

The following Debug-only launch arguments support deterministic UI verification:

- `--mock-glance=shared-walk,paused` chooses the newest event;
- `--mock-glance-age=121` verifies two-minute expiry;
- `--watch-route=today`;
- `--watch-route=companionSettings`;
- `--watch-route=dailyMemory`.

These arguments compile only in Debug and require `-UITesting` for Mock glance
injection. Mock glance and task receipts live in the selected E2E storage
namespace, separately from real profile records. A replacement batch is
terminalized atomically: the displayed newest event, replaced older events,
expired events, and events suppressed because sensing is disabled or the
scenario is invalid cannot revive after relaunch.

## Explicitly Deferred

- G4 motion assets and the three legacy placeholder mapping removals.
- White Mori, which remains disabled and deferred in the G4 handoff.
- Physical Watch haptic feel, wrist-raise timing, frame pacing, battery, and
  thermal validation.
- G3 peer transport composition for the locally durable global preferences;
  paired-device convergence is not yet claimed.
- Rendering real synchronized `MoriDomain` events, task/coin ledgers, and sealed
  memories in the app composition root. G3 owns the durable event and memory
  policies; G5 verifies presentation and isolated Mock receipts only.

## Acceptance

- Debug and Release Watch schemes build.
- The 23-test Watch UI suite passes on the 46 mm primary simulator.
- Home, companion settings, and daily memory are visually reviewed with
  Computer Use; the 40 mm home receives a second visible review.
- Home, companion settings, daily memory, and primary accessibility pass on
  the 40 mm simulator.
- Accessibility audit covers home, companion settings, daily memory, Today,
  total settings, letters, the long-press menu, and Touch Exchange states.
- Independent review passes with no P0 or P1 findings.
- Physical-device behavior remains `DEVICE_UNVERIFIED`.
