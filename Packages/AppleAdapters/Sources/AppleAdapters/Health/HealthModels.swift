import Foundation

public enum HealthAccessRequestState: Equatable, Sendable {
  case notRequested
  case requestCompleted
  case unavailable(reason: String)
}

/// HealthKit does not expose whether read access was granted for an individual type.
/// Callers must use this data-level result instead of inferring read authorization.
public enum HealthDataAvailability: Equatable, Sendable {
  case available
  case noData
  case unavailable(reason: String)
}

public struct HealthQueryWindow: Equatable, Sendable {
  /// Start of the calendar day used for activity metrics such as steps and workouts.
  public let start: Date
  /// Earlier boundary used for overnight sleep that ends during the calendar day.
  public let sleepStart: Date
  public let end: Date

  public init(start: Date, sleepStart: Date? = nil, end: Date) {
    self.start = start
    self.sleepStart = sleepStart ?? start
    self.end = end
  }

  public var isValid: Bool { sleepStart <= start && start <= end }
}

public enum SleepStage: String, Codable, Equatable, Sendable {
  case awake
  case inBed
  case asleepUnspecified
  case core
  case deep
  case rem
}

public struct HealthSampleSource: Codable, Equatable, Hashable, Sendable {
  public let bundleIdentifier: String
  public let displayName: String
  public let productType: String?

  public init(bundleIdentifier: String, displayName: String, productType: String? = nil) {
    self.bundleIdentifier = bundleIdentifier
    self.displayName = displayName
    self.productType = productType
  }
}

public struct SleepSample: Codable, Equatable, Sendable {
  public let start: Date
  public let end: Date
  public let stage: SleepStage
  public let source: HealthSampleSource?

  public init(
    start: Date,
    end: Date,
    stage: SleepStage,
    source: HealthSampleSource? = nil
  ) {
    self.start = start
    self.end = end
    self.stage = stage
    self.source = source
  }
}

public struct TimedQuantity: Codable, Equatable, Sendable {
  public let start: Date
  public let end: Date
  public let value: Double
  public let source: HealthSampleSource?

  public init(start: Date, end: Date, value: Double, source: HealthSampleSource? = nil) {
    self.start = start
    self.end = end
    self.value = value
    self.source = source
  }
}

public enum WorkoutActivity: String, Codable, Equatable, Sendable {
  case soccer
  case walking
  case running
  case cycling
  case other
}

public struct WorkoutSample: Codable, Equatable, Sendable {
  public let id: UUID
  public let activity: WorkoutActivity
  public let start: Date
  public let end: Date
  public let durationSeconds: TimeInterval
  public let energyKilocalories: Double?
  public let distanceMeters: Double?
  public let source: HealthSampleSource?

  public init(
    id: UUID,
    activity: WorkoutActivity,
    start: Date,
    end: Date,
    durationSeconds: TimeInterval,
    energyKilocalories: Double? = nil,
    distanceMeters: Double? = nil,
    source: HealthSampleSource? = nil
  ) {
    self.id = id
    self.activity = activity
    self.start = start
    self.end = end
    self.durationSeconds = durationSeconds
    self.energyKilocalories = energyKilocalories
    self.distanceMeters = distanceMeters
    self.source = source
  }
}

public struct HealthReading<Value: Equatable & Sendable>: Equatable, Sendable {
  public let availability: HealthDataAvailability
  public let values: Value

  public init(availability: HealthDataAvailability, values: Value) {
    self.availability = availability
    self.values = values
  }
}

public struct HealthSnapshot: Equatable, Sendable {
  public let capturedAt: Date
  public let sleep: HealthReading<[SleepSample]>
  public let steps: HealthReading<[TimedQuantity]>
  public let restingHeartRate: HealthReading<[TimedQuantity]>
  public let workouts: HealthReading<[WorkoutSample]>

  public init(
    capturedAt: Date,
    sleep: HealthReading<[SleepSample]>,
    steps: HealthReading<[TimedQuantity]>,
    restingHeartRate: HealthReading<[TimedQuantity]>,
    workouts: HealthReading<[WorkoutSample]>
  ) {
    self.capturedAt = capturedAt
    self.sleep = sleep
    self.steps = steps
    self.restingHeartRate = restingHeartRate
    self.workouts = workouts
  }
}

public protocol HealthDataClient: Sendable {
  func accessRequestState() async -> HealthAccessRequestState
  func requestAccess() async -> HealthAccessRequestState
  func fetchSnapshot(in window: HealthQueryWindow) async throws -> HealthSnapshot
}

public enum HealthAdapterError: Error, Equatable, Sendable {
  case invalidQueryWindow
  case queryFailed(String)
}
