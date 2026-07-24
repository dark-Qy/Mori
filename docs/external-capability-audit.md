# External Capability Audit

- Audit date: 2026-07-24
- Repository revision: `e4265fe`
- Machine scope: current Codex workspace host

## Conclusion

The current machine can build and test iOS and watchOS applications in
Simulator. It cannot provide honest physical-device validation: no iPhone or
Watch is connected, no simulator pair is configured, and no valid code-signing
identity is installed.

Simulator and Mock evidence may validate application behavior. It does not
validate physical HealthKit access, background sampling, haptic feel, Focus
delivery, wrist activation, WatchConnectivity between paired hardware, Nearby
Interaction, battery, thermal behavior, or frame pacing on a device.

## Toolchain And Hardware

| Capability | Evidence | Status |
| --- | --- | --- |
| Xcode | `/Applications/Xcode.app`, Xcode 26.6 build 17F113 | AVAILABLE |
| Default developer directory | `xcode-select -p` returns `/Library/Developer/CommandLineTools` | MISCONFIGURED; commands must set `DEVELOPER_DIR` |
| SDKs | iOS, iOS Simulator, watchOS, and watchOS Simulator 26.5 | AVAILABLE |
| iPhone Simulators | Five available; all stopped at final audit | AVAILABLE, NOT BOOTED |
| Watch Simulators | Five available; all stopped at final audit | AVAILABLE, NOT BOOTED |
| Simulator pairing | `simctl list pairs` is empty | UNAVAILABLE |
| Physical Apple devices | `devicectl` reports none; `xcdevice` lists only the Mac | NONE DETECTED |
| Code signing | `security find-identity -v -p codesigning` reports zero valid identities | UNAVAILABLE |
| Development team | No `DEVELOPMENT_TEAM`; targets use automatic signing | UNCONFIGURED |
| Second Watch for Touch Exchange | No physical Watch is connected | UNAVAILABLE |
| Apple/test account | No signed-in test account or account-dependent fixture was inspected; current Simulator baselines use local deterministic data | NOT ASSESSED; no account claim |
| Remote Chat/social test identity | No production identity, provider account, or social processor test tenant is configured for this audit | UNAVAILABLE |
| Health/location/motion permission state | No physical device exists; Simulator permission dialogs were not used as evidence for real authorization | PHYSICAL STATE UNAVAILABLE |
| Notification/Focus permission state | No physical Watch/iPhone pair or Focus test window exists | PHYSICAL STATE UNAVAILABLE |

Use the full Xcode toolchain explicitly:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The host-wide `xcode-select` setting is not changed by this Goal.

## Product Capability Boundary

| Product capability | Repository and environment evidence | Current status |
| --- | --- | --- |
| HealthKit foreground authorization and reads | Entitlements and adapter exist for authorization, sleep, steps, resting heart rate, workout, and state of mind | IMPLEMENTED PATH; PHYSICAL RESULT UNVERIFIED |
| HealthKit background delivery | No `HKObserverQuery` or `enableBackgroundDelivery` implementation found | NOT IMPLEMENTED |
| Coarse location inference | Simulator can inject location, but the app has no Core Location adapter or usage description | NOT IMPLEMENTED |
| Motion inference | No Core Motion or `CMPedometer` adapter found | NOT IMPLEMENTED |
| Watch haptics | Calls exist for click, direction-up, success, and notification haptics | CODE PATH EXISTS; FEEL UNVERIFIED |
| Focus and quiet delivery | Local notification code exists; no physical Focus test environment | UNVERIFIED |
| Wrist activation | App foreground activation can be observed; watchOS cannot promise a wrist-raise callback | BEST-EFFORT DESIGN ONLY |
| WatchConnectivity | Application-context client and unit-testable merge paths exist | IMPLEMENTED PATH; PAIRED E2E UNVERIFIED |
| Nearby Interaction | Client code and usage copy exist; required entitlement/configuration and second device are unavailable | CONFIGURATION GAP; PHYSICAL E2E UNVERIFIED |
| Frame pacing, memory, thermal, battery | Simulator may reveal gross defects only | PHYSICAL MEASUREMENT UNVERIFIED |

## Evidence Commands

```sh
xcode-select -p
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -showsdks
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl list devices available
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl list devices booted
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl list pairs
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl list devices
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xcdevice list
security find-identity -v -p codesigning
```

Repository evidence:

- `Packages/AppleAdapters/Sources/AppleAdapters/Health/AppleHealthKitClient.swift`
- `Packages/AppleAdapters/Sources/AppleAdapters/Connectivity/AppleWatchConnectivityClient.swift`
- `Apps/Apple/WatchApp/Features/PetHome/CompanionSceneView.swift`
- `Apps/Apple/iPhoneApp/Resources/WatchCompanion.entitlements`
- `Apps/Apple/WatchApp/Resources/WatchCompanionWatch.entitlements`

## Required Future Device Runbook

The physical gate remains `UNVERIFIED` until all of the following evidence is
captured against the same release candidate:

1. configure a real signing team and install the paired iPhone and Watch builds;
2. record HealthKit grant, partial grant, denial, revocation, stale data, and
   fresh data on each device;
3. verify background and foreground evidence behavior without claiming
   guaranteed continuous monitoring;
4. test quiet hours and Focus with no haptic, permitted haptic, delayed
   notification, and missed notification;
5. disconnect and reconnect the paired devices while issuing and completing
   tasks, settling coins, sealing a memory, changing preferences, and deleting
   data;
6. verify actual haptic comfort and the no-haptic alternative;
7. use two eligible devices for Touch Exchange, including denial, cancellation,
   timeout, and uncertain cancellation;
8. record frame pacing, decoded asset memory, thermal behavior, battery impact,
   and foreground duration on the smallest and largest supported Watch.

The absence of hardware is an external validation boundary, not permission to
replace these gates with simulator PASS claims.
