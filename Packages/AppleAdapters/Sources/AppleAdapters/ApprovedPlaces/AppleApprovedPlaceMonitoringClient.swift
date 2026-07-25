#if canImport(CoreLocation) && (os(iOS) || os(macOS))
  @preconcurrency import CoreLocation
  import Foundation

  @MainActor
  public final class AppleApprovedPlaceMonitoringClient: NSObject,
    ApprovedPlaceMonitoringClient, @preconcurrency CLLocationManagerDelegate, @unchecked Sendable
  {
    public static let maximumRegionCount = 20
    private static let managedIdentifierPrefix = "MoriApprovedPlace."

    private struct ActiveRegion {
      let category: ApprovedPlaceCategory
      let region: CLCircularRegion
    }

    private let manager: CLLocationManager
    private nonisolated let eventBroadcaster =
      AdapterEventBroadcaster<ApprovedPlaceMonitoringEvent>()
    private var activeRegions: [String: ActiveRegion] = [:]
    private var callbackGeneration = UUID()
    private var lastReportedPermission: ApprovedPlacePermissionState?

    public override init() {
      manager = CLLocationManager()
      super.init()
      manager.delegate = self
      for region in manager.monitoredRegions
      where region.identifier.hasPrefix(Self.managedIdentifierPrefix) {
        manager.stopMonitoring(for: region)
      }
      lastReportedPermission = Self.permissionState(from: manager.authorizationStatus)
    }

    public func availability() -> ApprovedPlaceMonitoringAvailability {
      guard CLLocationManager.locationServicesEnabled() else {
        return .unavailable(reason: "Location Services are disabled")
      }
      guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
        return .unavailable(reason: "Circular-region monitoring is unavailable on this device")
      }
      return .available
    }

    public func permissionState() -> ApprovedPlacePermissionState {
      guard CLLocationManager.locationServicesEnabled() else {
        return .unavailable(reason: "Location Services are disabled")
      }
      return Self.permissionState(from: manager.authorizationStatus)
    }

    public func requestPermission(_ request: ApprovedPlacePermissionRequest) {
      switch request {
      case .whenInUse:
        manager.requestWhenInUseAuthorization()
      case .always:
        manager.requestAlwaysAuthorization()
      }
    }

    public nonisolated func events() -> AsyncStream<ApprovedPlaceMonitoringEvent> {
      eventBroadcaster.stream()
    }

    public func startMonitoring(_ regions: [DeviceLocalApprovedRegion]) throws {
      let currentAvailability = availability()
      guard currentAvailability == .available else {
        let reason = Self.unavailableReason(from: currentAvailability)
        eventBroadcaster.yield(.failed(.unavailable(reason)))
        throw ApprovedPlaceAdapterError.unavailable(reason)
      }
      try validateCurrentPermission()
      do {
        try DeviceLocalApprovedRegion.validate(regions, maximum: Self.maximumRegionCount)
      } catch let error as ApprovedPlaceAdapterError {
        Self.report(error, broadcaster: eventBroadcaster)
        throw error
      }

      stopActiveRegions(emitStopped: false)
      callbackGeneration = UUID()
      let generationPrefix =
        "\(Self.managedIdentifierPrefix)\(callbackGeneration.uuidString)"
      for (index, approvedRegion) in regions.enumerated() {
        let identifier = "\(generationPrefix).\(index)"
        let region = CLCircularRegion(
          center: CLLocationCoordinate2D(
            latitude: approvedRegion.center.latitude,
            longitude: approvedRegion.center.longitude
          ),
          radius: approvedRegion.radiusMeters,
          identifier: identifier
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        activeRegions[identifier] = ActiveRegion(
          category: approvedRegion.category,
          region: region
        )
        manager.startMonitoring(for: region)
      }
    }

    public func stop() {
      stopActiveRegions(emitStopped: true)
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
      let permission = permissionState()
      guard permission != lastReportedPermission else { return }
      lastReportedPermission = permission
      eventBroadcaster.yield(.permissionChanged(permission))
      guard !activeRegions.isEmpty else { return }
      switch permission {
      case .authorizedWhenInUse, .authorizedAlways:
        return
      case .notDetermined:
        stopActiveRegions(emitStopped: false)
        eventBroadcaster.yield(.failed(.permissionNotDetermined))
      case .denied:
        stopActiveRegions(emitStopped: false)
        eventBroadcaster.yield(.failed(.permissionDenied))
      case .restricted:
        stopActiveRegions(emitStopped: false)
        eventBroadcaster.yield(.failed(.permissionRestricted))
      case .unavailable(let reason):
        stopActiveRegions(emitStopped: false)
        eventBroadcaster.yield(.failed(.unavailable(reason)))
      }
    }

    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
      emitObservation(for: region.identifier, presence: .entered, observedAt: Date())
    }

    public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
      emitObservation(for: region.identifier, presence: .exited, observedAt: Date())
    }

    public func locationManager(
      _ manager: CLLocationManager,
      monitoringDidFailFor region: CLRegion?,
      withError _: any Error
    ) {
      guard
        let identifier = region?.identifier,
        activeRegions.removeValue(forKey: identifier) != nil
      else { return }
      // Core Location errors may carry a CLRegion in userInfo. Never surface the
      // arbitrary description because it can contain the region center or radius.
      eventBroadcaster.yield(.failed(.systemFailure))
    }

    private func emitObservation(
      for identifier: String,
      presence: ApprovedPlacePresence,
      observedAt: Date
    ) {
      // The session-specific identifier fences callbacks delivered after stop or replacement.
      guard let approvedRegion = activeRegions[identifier] else { return }
      eventBroadcaster.yield(
        .observation(
          ApprovedPlaceObservation(
            category: approvedRegion.category,
            presence: presence,
            observedAt: observedAt
          )
        )
      )
    }

    private func stopActiveRegions(emitStopped: Bool) {
      callbackGeneration = UUID()
      let regions = Array(activeRegions.values.map(\.region))
      activeRegions.removeAll()
      for region in regions {
        manager.stopMonitoring(for: region)
      }
      if emitStopped {
        eventBroadcaster.yield(.stopped)
      }
    }

    private func validateCurrentPermission() throws {
      switch permissionState() {
      case .authorizedWhenInUse, .authorizedAlways:
        return
      case .notDetermined:
        eventBroadcaster.yield(.failed(.permissionNotDetermined))
        throw ApprovedPlaceAdapterError.permissionNotDetermined
      case .denied:
        eventBroadcaster.yield(.failed(.permissionDenied))
        throw ApprovedPlaceAdapterError.permissionDenied
      case .restricted:
        eventBroadcaster.yield(.failed(.permissionRestricted))
        throw ApprovedPlaceAdapterError.permissionRestricted
      case .unavailable(let reason):
        eventBroadcaster.yield(.failed(.unavailable(reason)))
        throw ApprovedPlaceAdapterError.unavailable(reason)
      }
    }

    private static func permissionState(
      from status: CLAuthorizationStatus
    ) -> ApprovedPlacePermissionState {
      switch status {
      case .notDetermined: .notDetermined
      case .restricted: .restricted
      case .denied: .denied
      case .authorizedAlways: .authorizedAlways
      case .authorizedWhenInUse: .authorizedWhenInUse
      @unknown default: .unavailable(reason: "Unknown Core Location authorization state")
      }
    }

    private static func report(
      _ error: ApprovedPlaceAdapterError,
      broadcaster: AdapterEventBroadcaster<ApprovedPlaceMonitoringEvent>
    ) {
      switch error {
      case .invalidRegion:
        broadcaster.yield(.failed(.invalidRegion))
      case .tooManyRegions(let maximum):
        broadcaster.yield(.failed(.tooManyRegions(maximum: maximum)))
      case .unavailable(let reason):
        broadcaster.yield(.failed(.unavailable(reason)))
      case .permissionNotDetermined:
        broadcaster.yield(.failed(.permissionNotDetermined))
      case .permissionDenied:
        broadcaster.yield(.failed(.permissionDenied))
      case .permissionRestricted:
        broadcaster.yield(.failed(.permissionRestricted))
      }
    }

    private static func unavailableReason(
      from availability: ApprovedPlaceMonitoringAvailability
    ) -> String {
      switch availability {
      case .available:
        "Approved-place monitoring is available"
      case .unavailable(let reason):
        reason
      }
    }
  }
#else
  import Foundation

  /// watchOS does not expose circular-region monitoring. Compose the iPhone live adapter
  /// and transfer only approved category observations to the Watch.
  public actor AppleApprovedPlaceMonitoringClient: ApprovedPlaceMonitoringClient {
    private nonisolated let eventBroadcaster =
      AdapterEventBroadcaster<ApprovedPlaceMonitoringEvent>()
    private let reason = "Approved-place region monitoring is unavailable on this platform"

    public init() {}

    public func availability() -> ApprovedPlaceMonitoringAvailability {
      .unavailable(reason: reason)
    }

    public func permissionState() -> ApprovedPlacePermissionState {
      .unavailable(reason: reason)
    }

    public func requestPermission(_ request: ApprovedPlacePermissionRequest) {}

    public nonisolated func events() -> AsyncStream<ApprovedPlaceMonitoringEvent> {
      eventBroadcaster.stream()
    }

    public func startMonitoring(_ regions: [DeviceLocalApprovedRegion]) throws {
      eventBroadcaster.yield(.failed(.unavailable(reason)))
      throw ApprovedPlaceAdapterError.unavailable(reason)
    }

    public func stop() {
      eventBroadcaster.yield(.stopped)
    }
  }
#endif
