# AppRuntime

`AppRuntime` is the composition boundary between Apple framework adapters and the deterministic
product domain. It owns mapping, local proactive-interaction orchestration, and user preferences.

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
