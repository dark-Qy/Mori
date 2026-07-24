#if canImport(CoreMotion) && (os(iOS) || os(watchOS))
  @preconcurrency import CoreMotion
  import Foundation

  public final class AppleBroadMotionActivityClient: BroadMotionActivityClient, @unchecked Sendable
  {
    private let manager: CMMotionActivityManager
    private let operationQueue: OperationQueue
    private let lock = NSLock()
    private let eventBroadcaster = AdapterEventBroadcaster<BroadMotionEvent>()
    private var activeCallbackID: UUID?
    private var lastReportedPermission: MotionPermissionState?

    public init() {
      manager = CMMotionActivityManager()
      operationQueue = OperationQueue()
      operationQueue.name = "Mori.BroadMotionActivity"
      operationQueue.maxConcurrentOperationCount = 1
      operationQueue.qualityOfService = .utility
    }

    public func availability() async -> MotionClassifierAvailability {
      Self.currentAvailability()
    }

    public func permissionState() async -> MotionPermissionState {
      Self.currentPermissionState()
    }

    public func events() -> AsyncStream<BroadMotionEvent> {
      eventBroadcaster.stream()
    }

    public func start() async throws {
      guard Self.currentAvailability() == .available else {
        let reason = "Broad motion classification is unavailable on this device"
        eventBroadcaster.yield(.failed(.unavailable(reason)))
        throw BroadMotionAdapterError.unavailable(reason)
      }

      switch Self.currentPermissionState() {
      case .authorized, .notDetermined:
        break
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

      let callbackID = UUID()
      lock.withLock {
        activeCallbackID = callbackID
        lastReportedPermission = Self.currentPermissionState()
        manager.startActivityUpdates(to: operationQueue) { [weak self] activity in
          self?.receive(activity, callbackID: callbackID)
        }
      }
    }

    public func stop() async {
      lock.withLock {
        activeCallbackID = nil
        manager.stopActivityUpdates()
        eventBroadcaster.yield(.stopped)
      }
    }

    private func receive(_ activity: CMMotionActivity?, callbackID: UUID) {
      lock.withLock {
        guard activeCallbackID == callbackID else { return }

        let permission = Self.currentPermissionState()
        if lastReportedPermission != permission {
          lastReportedPermission = permission
          eventBroadcaster.yield(.permissionChanged(permission))
        }

        switch permission {
        case .authorized:
          break
        case .notDetermined:
          activeCallbackID = nil
          manager.stopActivityUpdates()
          eventBroadcaster.yield(.failed(.permissionNotDetermined))
          return
        case .denied:
          activeCallbackID = nil
          manager.stopActivityUpdates()
          eventBroadcaster.yield(.failed(.permissionDenied))
          return
        case .restricted:
          activeCallbackID = nil
          manager.stopActivityUpdates()
          eventBroadcaster.yield(.failed(.permissionRestricted))
          return
        case .unavailable(let reason):
          activeCallbackID = nil
          manager.stopActivityUpdates()
          eventBroadcaster.yield(.failed(.unavailable(reason)))
          return
        }

        guard let activity else {
          eventBroadcaster.yield(.failed(.classifierReturnedNoObservation))
          return
        }
        eventBroadcaster.yield(
          .observation(
            BroadMotionObservation(
              activity: Self.broadActivity(from: activity),
              confidence: Self.confidence(from: activity.confidence),
              observedAt: activity.startDate
            )
          )
        )
      }
    }

    private static func currentAvailability() -> MotionClassifierAvailability {
      CMMotionActivityManager.isActivityAvailable()
        ? .available
        : .unavailable(reason: "Broad motion classification is unavailable on this device")
    }

    private static func currentPermissionState() -> MotionPermissionState {
      guard CMMotionActivityManager.isActivityAvailable() else {
        return .unavailable(reason: "Broad motion classification is unavailable on this device")
      }
      return switch CMMotionActivityManager.authorizationStatus() {
      case .notDetermined: .notDetermined
      case .restricted: .restricted
      case .denied: .denied
      case .authorized: .authorized
      @unknown default: .unavailable(reason: "Unknown Core Motion authorization state")
      }
    }

    private static func broadActivity(from activity: CMMotionActivity) -> BroadMotionActivity {
      // Core Motion flags are not mutually exclusive. This order selects one stable,
      // deliberately broad result without exposing any raw sensor values.
      if activity.automotive { return .automotive }
      if activity.cycling { return .cycling }
      if activity.running { return .running }
      if activity.walking { return .walking }
      if activity.stationary { return .stationary }
      return .unknown
    }

    private static func confidence(
      from confidence: CMMotionActivityConfidence
    ) -> MotionClassifierConfidence {
      switch confidence {
      case .low: .low
      case .medium: .medium
      case .high: .high
      @unknown default: .low
      }
    }
  }
#else
  import Foundation

  /// A compile-safe fallback for platforms where live Core Motion activity classification
  /// is unavailable. Apps can still compose the protocol with a deterministic mock.
  public actor AppleBroadMotionActivityClient: BroadMotionActivityClient {
    private nonisolated let eventBroadcaster = AdapterEventBroadcaster<BroadMotionEvent>()
    private let reason = "Broad motion classification is unavailable on this platform"

    public init() {}

    public func availability() -> MotionClassifierAvailability {
      .unavailable(reason: reason)
    }

    public func permissionState() -> MotionPermissionState {
      .unavailable(reason: reason)
    }

    public nonisolated func events() -> AsyncStream<BroadMotionEvent> {
      eventBroadcaster.stream()
    }

    public func start() throws {
      eventBroadcaster.yield(.failed(.unavailable(reason)))
      throw BroadMotionAdapterError.unavailable(reason)
    }

    public func stop() {
      eventBroadcaster.yield(.stopped)
    }
  }
#endif
