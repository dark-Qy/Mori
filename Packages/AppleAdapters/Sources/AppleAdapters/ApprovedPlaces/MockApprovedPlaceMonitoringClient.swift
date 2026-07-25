import Foundation

public actor MockApprovedPlaceMonitoringClient: ApprovedPlaceMonitoringClient {
  public static let maximumRegionCount = 20

  private let reportedAvailability: ApprovedPlaceMonitoringAvailability
  private nonisolated let eventBroadcaster =
    AdapterEventBroadcaster<ApprovedPlaceMonitoringEvent>()
  private var reportedPermission: ApprovedPlacePermissionState
  private var activeCategories: Set<ApprovedPlaceCategory> = []
  private var generation: UInt64 = 0
  private var running = false

  public init(
    availability: ApprovedPlaceMonitoringAvailability = .available,
    permission: ApprovedPlacePermissionState = .authorizedWhenInUse
  ) {
    reportedAvailability = availability
    reportedPermission = permission
  }

  public func availability() -> ApprovedPlaceMonitoringAvailability { reportedAvailability }

  public func permissionState() -> ApprovedPlacePermissionState { reportedPermission }

  public func requestPermission(_ request: ApprovedPlacePermissionRequest) {
    guard reportedPermission == .notDetermined else { return }
    reportedPermission =
      switch request {
      case .whenInUse: .authorizedWhenInUse
      case .always: .authorizedAlways
      }
    eventBroadcaster.yield(.permissionChanged(reportedPermission))
  }

  public nonisolated func events() -> AsyncStream<ApprovedPlaceMonitoringEvent> {
    eventBroadcaster.stream()
  }

  public func startMonitoring(_ regions: [DeviceLocalApprovedRegion]) throws {
    guard reportedAvailability == .available else {
      let reason = Self.unavailableReason(from: reportedAvailability)
      eventBroadcaster.yield(.failed(.unavailable(reason)))
      throw ApprovedPlaceAdapterError.unavailable(reason)
    }
    try Self.validatePermission(reportedPermission, broadcaster: eventBroadcaster)
    do {
      try DeviceLocalApprovedRegion.validate(regions, maximum: Self.maximumRegionCount)
    } catch let error as ApprovedPlaceAdapterError {
      Self.report(error, broadcaster: eventBroadcaster)
      throw error
    }

    generation &+= 1
    running = true
    activeCategories = Set(regions.map(\.category))
  }

  public func stop() {
    generation &+= 1
    running = false
    activeCategories = []
    eventBroadcaster.yield(.stopped)
  }

  /// Exposes a deterministic callback generation to tests and previews. A value captured
  /// before `stop()` or a replacement `startMonitoring(_:)` is fenced.
  public func currentCallbackGeneration() -> UInt64 { generation }

  public func isMonitoring() -> Bool { running }

  public func emit(
    category: ApprovedPlaceCategory,
    presence: ApprovedPlacePresence,
    observedAt: Date,
    callbackGeneration: UInt64? = nil
  ) {
    guard
      running,
      activeCategories.contains(category),
      callbackGeneration == nil || callbackGeneration == generation
    else { return }
    eventBroadcaster.yield(
      .observation(
        ApprovedPlaceObservation(
          category: category,
          presence: presence,
          observedAt: observedAt
        )
      )
    )
  }

  public func setPermissionState(_ permission: ApprovedPlacePermissionState) {
    guard permission != reportedPermission else { return }
    reportedPermission = permission
    eventBroadcaster.yield(.permissionChanged(permission))
    guard
      running,
      permission != .authorizedWhenInUse,
      permission != .authorizedAlways
    else { return }
    generation &+= 1
    running = false
    activeCategories = []
    switch permission {
    case .notDetermined:
      eventBroadcaster.yield(.failed(.permissionNotDetermined))
    case .denied:
      eventBroadcaster.yield(.failed(.permissionDenied))
    case .restricted:
      eventBroadcaster.yield(.failed(.permissionRestricted))
    case .unavailable(let reason):
      eventBroadcaster.yield(.failed(.unavailable(reason)))
    case .authorizedWhenInUse, .authorizedAlways:
      break
    }
  }

  public func simulateSystemFailure(callbackGeneration: UInt64? = nil) {
    guard
      running,
      callbackGeneration == nil || callbackGeneration == generation
    else { return }
    eventBroadcaster.yield(.failed(.systemFailure))
  }

  private static func validatePermission(
    _ permission: ApprovedPlacePermissionState,
    broadcaster: AdapterEventBroadcaster<ApprovedPlaceMonitoringEvent>
  ) throws {
    switch permission {
    case .authorizedWhenInUse, .authorizedAlways:
      return
    case .notDetermined:
      broadcaster.yield(.failed(.permissionNotDetermined))
      throw ApprovedPlaceAdapterError.permissionNotDetermined
    case .denied:
      broadcaster.yield(.failed(.permissionDenied))
      throw ApprovedPlaceAdapterError.permissionDenied
    case .restricted:
      broadcaster.yield(.failed(.permissionRestricted))
      throw ApprovedPlaceAdapterError.permissionRestricted
    case .unavailable(let reason):
      broadcaster.yield(.failed(.unavailable(reason)))
      throw ApprovedPlaceAdapterError.unavailable(reason)
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
