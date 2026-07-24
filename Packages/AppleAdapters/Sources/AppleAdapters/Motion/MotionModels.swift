import Foundation

/// A deliberately broad classifier result. The adapter never exposes accelerometer,
/// gyroscope, or other raw motion samples.
public enum BroadMotionActivity: String, Codable, CaseIterable, Equatable, Sendable {
  case stationary
  case walking
  case running
  case cycling
  case automotive
  case unknown
}

public enum MotionClassifierConfidence: String, Codable, CaseIterable, Equatable, Sendable {
  case low
  case medium
  case high
}

public struct BroadMotionObservation: Codable, Equatable, Sendable {
  public let activity: BroadMotionActivity
  public let confidence: MotionClassifierConfidence
  public let observedAt: Date

  public init(
    activity: BroadMotionActivity,
    confidence: MotionClassifierConfidence,
    observedAt: Date
  ) {
    self.activity = activity
    self.confidence = confidence
    self.observedAt = observedAt
  }
}

public enum MotionClassifierAvailability: Equatable, Sendable {
  case available
  case unavailable(reason: String)
}

public enum MotionPermissionState: Equatable, Sendable {
  case notDetermined
  case authorized
  case denied
  case restricted
  case unavailable(reason: String)
}

public enum BroadMotionFailure: Equatable, Sendable {
  case unavailable(String)
  case permissionNotDetermined
  case permissionDenied
  case permissionRestricted
  case classifierReturnedNoObservation
}

public enum BroadMotionEvent: Equatable, Sendable {
  case observation(BroadMotionObservation)
  case permissionChanged(MotionPermissionState)
  case stopped
  case failed(BroadMotionFailure)
}

public protocol BroadMotionActivityClient: Sendable {
  func availability() async -> MotionClassifierAvailability
  func permissionState() async -> MotionPermissionState
  func events() -> AsyncStream<BroadMotionEvent>
  func start() async throws
  func stop() async
}

public enum BroadMotionAdapterError: Error, Equatable, Sendable {
  case unavailable(String)
  case permissionDenied
  case permissionRestricted
}
