# AppRuntime

`AppRuntime` is the composition boundary between Apple framework adapters and the deterministic
product domain. It owns mapping, local proactive-interaction orchestration, and user preferences.

The package exposes two runtime layers during the Mori rebuild:

- `AppRuntime` keeps the existing Apple application composition available while the presentation
  stores migrate.
- `MoriRuntime` owns the new profile-aware evidence, inference, and sensing boundary. It composes
  either a complete production dependency set or a complete deterministic local dependency set;
  it never mixes the two.

- Adapter models are normalized before they reach rules.
- Missing HealthKit values remain `nil`; request completion is never treated as read permission.
- Sleep stages exclude `inBed` and `awake` from asleep duration.
- Health events have deterministic semantic IDs and remain safe under repeated ingestion.
- Notification text and timing must be approved by rules before reaching the adapter; AI cannot
  create or schedule a notification.
- Public pet-card sharing is on by default and still requires bilateral Watch confirmation.
  The Phone projection carries a versioned authority marker; until Watch has a trusted value it
  does not construct the exchange network client. An explicit opt-out remains off across upgrades.
  A Phone preference-read failure publishes no social authority. Care summary is only a future
  configurable scope and is not part of touch exchange.
- Clothing is stored as a cosmetic preference only.
- Onboarding and management preferences persist locally; a legacy schema-1 record migrates without
  forcing an existing installation through onboarding again.
- A file-backed latest-value outbox coalesces management changes and retries after relaunch without
  blocking local pet progression. Only allowlisted pet display, wardrobe, and notification values
  enter the WatchConnectivity projection.
- Notification responses map to bounded presentation destinations and never settle rewards.
- Apple-platform composition keeps HealthKit, notifications, WatchConnectivity, and durable event
  storage outside SwiftUI views.

## Current Implementation Priority

The active implementation path is Mock-first. Debug builds use isolated, deterministic Mori
profiles and the seven scenarios documented in [`docs/mock-data.md`](../../docs/mock-data.md).
They exercise the real reducers, persistence, profile transitions, and presentation inputs without
requesting system permissions or constructing production adapters.

The current gate proves application behavior and data isolation. It does not claim physical-device
HealthKit, motion, location, background delivery, haptics, paired-device transport, power, or
thermal behavior. Those adapters remain behind the production composition boundary and are a later
device-validation goal.
