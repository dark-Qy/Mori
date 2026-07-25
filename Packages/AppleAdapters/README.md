# AppleAdapters

`AppleAdapters` isolates Apple-only capabilities behind framework-neutral protocols. Product and
domain targets should depend on these protocols, while app composition chooses a live or mock
implementation.

## Boundaries

- `HealthDataClient` reads sleep analysis, steps, resting heart rate, and workouts. A completed
  HealthKit request is **not** represented as per-type read authorization; each result reports its
  own data availability.
- `LocalNotificationClient` requests local-notification permission and schedules/cancels stable
  identifiers. Deep links use the package's own payload model. Quiet hours and cooldown are
  deterministic policy decisions.
- `CompanionStateSyncClient` transfers a small revisioned application state through
  WatchConnectivity. An exact retry of the last accepted state is idempotent; a conflicting same
  revision or stale revision cannot replace newer state.
- `NearbyRangingClient` exchanges encoded discovery tokens and reports distance. Nearby
  Interaction is **not a data transport**; token and business-data exchange require another
  channel.
- `BroadMotionActivityClient` emits only a broad activity, classifier confidence, and observation
  time. It never exposes accelerometer, gyroscope, or other raw motion samples. Live updates stop
  while the app is suspended; the adapter makes no background-continuity claim.
- `ApprovedPlaceMonitoringClient` accepts user-approved device-local circular regions but emits
  only the approved category, enter/exit state, and observation time. Coordinates and routes are
  never emitted. Circular-region monitoring is implemented on iPhone/macOS; watchOS reports an
  explicit unavailable state and can consume privacy-minimized category observations transferred
  by the companion app.
- `SmartAlarmCapabilityProviding` is only a capability boundary. It intentionally makes no claim
  about extended-runtime delivery without physical-watch verification.

Both passive-sensing clients expose availability and permission state, provide deterministic
mocks, and fence callbacks from stopped or replaced sessions. Cancelling a consumer's
`AsyncStream` subscription releases that subscription; call `stop()` to stop the underlying
capability.

## Verification

```sh
swift-format lint --strict --recursive Package.swift Sources Tests
swift test
```

The package also cross-compiles against iOS and watchOS simulator SDKs. Simulator builds verify API
shape only; the following remain `UNVERIFIED` until tested with signed builds on physical devices:

- HealthKit prompts, user-selected read access, query results, and background delivery.
- Local notification timing, deep-link launch behavior, Focus interactions, and Watch haptics.
- WatchConnectivity pairing, reachability, transfer timing, and conflict behavior across devices.
- Nearby Interaction discovery-token exchange, UWB distance stability, foreground constraints, and
  unsupported-device fallback.
- Core Motion classification availability, authorization prompts, classifier quality, update
  timing, suspension behavior, and power impact.
- Core Location authorization prompts, circular-region capacity and accuracy, enter/exit timing,
  relaunch behavior, and power impact. No simulator or SDK build verifies background continuity.
- Smart Alarm extended-runtime eligibility, scheduling, wake delivery, and battery impact.
