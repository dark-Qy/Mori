# AppRuntime

`AppRuntime` is the composition boundary between Apple framework adapters and the deterministic
product domain. It owns mapping, local proactive-interaction orchestration, and user preferences.

- Adapter models are normalized before they reach rules.
- Missing HealthKit values remain `nil`; request completion is never treated as read permission.
- Sleep stages exclude `inBed` and `awake` from asleep duration.
- Health events have deterministic semantic IDs and remain safe under repeated ingestion.
- Notification text and timing must be approved by rules before reaching the adapter; AI cannot
  create or schedule a notification.
- Social sharing is off by default. If a user later enables it, care summary is the default scope.
- Clothing is stored as a cosmetic preference only.
- Apple-platform composition keeps HealthKit, notifications, WatchConnectivity, and durable event
  storage outside SwiftUI views.
