import Foundation

public actor MockBroadMotionActivityClient: BroadMotionActivityClient {
  private let reportedAvailability: MotionClassifierAvailability
  private nonisolated let eventBroadcaster = AdapterEventBroadcaster<BroadMotionEvent>()
  private var reportedPermission: MotionPermissionState
  private var generation: UInt64 = 0
  private var running = false

  public init(
    availability: MotionClassifierAvailability = .available,
    permission: MotionPermissionState = .authorized
  ) {
    reportedAvailability = availability
    reportedPermission = permission
  }

  public func availability() -> MotionClassifierAvailability { reportedAvailability }

  public func permissionState() -> MotionPermissionState { reportedPermission }

  public nonisolated func events() -> AsyncStream<BroadMotionEvent> {
    eventBroadcaster.stream()
  }

  public func start() throws {
    guard reportedAvailability == .available else {
      let reason = Self.unavailableReason(from: reportedAvailability)
      eventBroadcaster.yield(.failed(.unavailable(reason)))
      throw BroadMotionAdapterError.unavailable(reason)
    }
    switch reportedPermission {
    case .authorized, .notDetermined:
      generation &+= 1
      running = true
    case .denied:
      eventBroadcaster.yield(.failed(.permissionDenied))
      throw BroadMotionAdapterError.permissionDenied
    case .restricted:
      eventBroadcaster.yield(.failed(.permissionRestricted))
      throw BroadMotionAdapterError.permissionRestricted
    case .unavailable(let reason):
      eventBroadcaster.yield(.failed(.unavailable(reason)))
      throw BroadMotionAdapterError.unavailable(reason)
    }
  }

  public func stop() {
    generation &+= 1
    running = false
    eventBroadcaster.yield(.stopped)
  }

  /// Exposes a deterministic callback generation to tests and previews. A value captured
  /// before `stop()` or a later `start()` is fenced and cannot emit an observation.
  public func currentCallbackGeneration() -> UInt64 { generation }

  public func isRunning() -> Bool { running }

  public func emit(
    _ observation: BroadMotionObservation,
    callbackGeneration: UInt64? = nil
  ) {
    guard
      running,
      reportedPermission == .authorized,
      callbackGeneration == nil || callbackGeneration == generation
    else { return }
    eventBroadcaster.yield(.observation(observation))
  }

  public func setPermissionState(_ permission: MotionPermissionState) {
    guard permission != reportedPermission else { return }
    reportedPermission = permission
    eventBroadcaster.yield(.permissionChanged(permission))
    guard running, permission != .authorized else { return }
    generation &+= 1
    running = false
    switch permission {
    case .notDetermined:
      eventBroadcaster.yield(.failed(.permissionNotDetermined))
    case .denied:
      eventBroadcaster.yield(.failed(.permissionDenied))
    case .restricted:
      eventBroadcaster.yield(.failed(.permissionRestricted))
    case .unavailable(let reason):
      eventBroadcaster.yield(.failed(.unavailable(reason)))
    case .authorized:
      break
    }
  }

  private static func unavailableReason(
    from availability: MotionClassifierAvailability
  ) -> String {
    switch availability {
    case .available:
      "Motion classification is available"
    case .unavailable(let reason):
      reason
    }
  }
}
