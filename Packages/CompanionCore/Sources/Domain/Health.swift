import Foundation

/// HealthKit does not reveal whether read access for an individual type was denied.
/// This records only the request lifecycle the application can observe.
public enum HealthRequestState: String, Codable, CaseIterable, Sendable {
  case notRequested
  case requestCompleted
  case unavailable
}

public enum HealthDataAvailability: String, Codable, CaseIterable, Sendable {
  case noData
  case partial
  case available
}

public enum HealthDataFreshness: String, Codable, CaseIterable, Sendable {
  case noData
  case fresh
  case stale
}

public enum HealthSourceKind: String, Codable, CaseIterable, Sendable {
  case appleWatch
  case iPhone
  case thirdParty
  case manual
  case mock
  case unknown
}

public struct HealthSource: Codable, Equatable, Hashable, Sendable {
  public var identifier: String
  public var displayName: String
  public var kind: HealthSourceKind

  public init(identifier: String, displayName: String, kind: HealthSourceKind) {
    self.identifier = identifier
    self.displayName = displayName
    self.kind = kind
  }
}

public struct WorkoutSummary: Codable, Equatable, Hashable, Sendable {
  public enum Activity: String, Codable, Sendable {
    case soccer
    case swimming
    case badminton
    case tennis
    case walking
    case running
    case cycling
    case other
  }

  public var id: UUID
  public var activity: Activity
  public var startedAt: Date
  public var durationMinutes: Int
  public var activeEnergyKilocalories: Double?

  public init(
    id: UUID,
    activity: Activity,
    startedAt: Date,
    durationMinutes: Int,
    activeEnergyKilocalories: Double? = nil
  ) {
    self.id = id
    self.activity = activity
    self.startedAt = startedAt
    self.durationMinutes = max(0, durationMinutes)
    self.activeEnergyKilocalories = activeEnergyKilocalories
  }
}

public enum StateOfMindLabel: String, Codable, CaseIterable, Sendable {
  case anxious
  case stressed
  case worried
  case overwhelmed
  case other

  public var requestsGentleCare: Bool {
    switch self {
    case .anxious, .stressed, .worried, .overwhelmed: true
    case .other: false
    }
  }
}

/// A deliberately narrow projection of a state of mind the person explicitly logged.
/// Physiological values never construct this type.
public struct StateOfMindSample: Codable, Equatable, Hashable, Sendable {
  public var id: UUID
  public var recordedAt: Date
  public var valence: Double
  public var labels: Set<StateOfMindLabel>

  public init(
    id: UUID,
    recordedAt: Date,
    valence: Double,
    labels: Set<StateOfMindLabel>
  ) {
    self.id = id
    self.recordedAt = recordedAt
    self.valence = min(1, max(-1, valence))
    self.labels = labels
  }

  public var requestsGentleCare: Bool {
    labels.contains(where: \.requestsGentleCare)
  }
}

public struct SleepStageSummary: Codable, Equatable, Sendable {
  public var coreMinutes: Int
  public var deepMinutes: Int
  public var remMinutes: Int
  public var unspecifiedMinutes: Int
  public var awakeMinutes: Int

  public init(
    coreMinutes: Int = 0,
    deepMinutes: Int = 0,
    remMinutes: Int = 0,
    unspecifiedMinutes: Int = 0,
    awakeMinutes: Int = 0
  ) {
    self.coreMinutes = max(0, coreMinutes)
    self.deepMinutes = max(0, deepMinutes)
    self.remMinutes = max(0, remMinutes)
    self.unspecifiedMinutes = max(0, unspecifiedMinutes)
    self.awakeMinutes = max(0, awakeMinutes)
  }

  public var asleepMinutes: Int {
    coreMinutes + deepMinutes + remMinutes + unspecifiedMinutes
  }
}

public struct LocalDay: RawRepresentable, Codable, Equatable, Hashable, Comparable, Sendable {
  public let rawValue: String

  public init?(rawValue: String) {
    let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
    guard
      parts.count == 3,
      parts[0].count == 4,
      parts[1].count == 2,
      parts[2].count == 2,
      let year = Int(parts[0]),
      let month = Int(parts[1]),
      let day = Int(parts[2])
    else { return nil }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
      return nil
    }
    let validated = calendar.dateComponents([.year, .month, .day], from: date)
    guard validated.year == year, validated.month == month, validated.day == day else {
      return nil
    }
    self.rawValue = rawValue
  }

  public static func containing(_ date: Date, in timeZone: TimeZone) -> LocalDay {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return LocalDay(
      rawValue: String(
        format: "%04d-%02d-%02d",
        components.year ?? 1970,
        components.month ?? 1,
        components.day ?? 1
      )
    )!
  }

  public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let day = LocalDay(rawValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "LocalDay must be a valid yyyy-MM-dd date."
      )
    }
    self = day
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A normalized, provenance-aware input to the rule engine.
/// Optional metrics mean "unavailable", never zero.
public struct HealthSnapshot: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var capturedAt: Date
  public var timeZoneIdentifier: String
  public var localDay: LocalDay
  public var freshness: HealthDataFreshness
  public var requestState: HealthRequestState
  public var availability: HealthDataAvailability
  public var sources: [HealthSource]
  public var sleepMinutes: Int?
  public var sleepStages: SleepStageSummary?
  public var sleepWindowStart: Date?
  public var sleepWindowEnd: Date?
  public var steps: Int?
  public var activeMinutes: Int?
  public var restingHeartRateBPM: Double?
  public var workouts: [WorkoutSummary]
  /// Optional preserves compatibility with version-1 ledgers written before mental-wellbeing
  /// samples were supported. New snapshots encode an array.
  public var stateOfMindSamples: [StateOfMindSample]?

  public init(
    schemaVersion: Int = HealthSnapshot.currentSchemaVersion,
    capturedAt: Date,
    timeZoneIdentifier: String = "UTC",
    localDay: LocalDay? = nil,
    freshness: HealthDataFreshness,
    requestState: HealthRequestState,
    availability: HealthDataAvailability,
    sources: [HealthSource] = [],
    sleepMinutes: Int? = nil,
    sleepStages: SleepStageSummary? = nil,
    sleepWindowStart: Date? = nil,
    sleepWindowEnd: Date? = nil,
    steps: Int? = nil,
    activeMinutes: Int? = nil,
    restingHeartRateBPM: Double? = nil,
    workouts: [WorkoutSummary] = [],
    stateOfMindSamples: [StateOfMindSample] = []
  ) {
    self.schemaVersion = schemaVersion
    self.capturedAt = capturedAt
    let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
    self.timeZoneIdentifier = timeZone.identifier
    self.localDay = localDay ?? LocalDay.containing(capturedAt, in: timeZone)
    self.freshness = freshness
    self.requestState = requestState
    self.availability = availability
    self.sources = sources
    self.sleepMinutes = sleepMinutes.map { max(0, $0) }
    self.sleepStages = sleepStages
    self.sleepWindowStart = sleepWindowStart
    self.sleepWindowEnd = sleepWindowEnd
    self.steps = steps.map { max(0, $0) }
    self.activeMinutes = activeMinutes.map { max(0, $0) }
    self.restingHeartRateBPM = restingHeartRateBPM
    self.workouts = workouts
    self.stateOfMindSamples = stateOfMindSamples.sorted {
      if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  public var hasAnyMetric: Bool {
    sleepMinutes != nil || steps != nil || activeMinutes != nil || restingHeartRateBPM != nil
      || !workouts.isEmpty || !(stateOfMindSamples ?? []).isEmpty
  }

  public var latestStateOfMind: StateOfMindSample? {
    stateOfMindSamples?.max {
      if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  public var latestCareStateOfMind: StateOfMindSample? {
    stateOfMindSamples?
      .filter(\.requestsGentleCare)
      .max {
        if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
        return $0.id.uuidString < $1.id.uuidString
      }
  }

  public var canInformRules: Bool {
    requestState == .requestCompleted && availability != .noData && freshness == .fresh
      && hasAnyMetric
  }

  public var hasConsistentSettlementDay: Bool {
    guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return false }
    return localDay == LocalDay.containing(capturedAt, in: timeZone)
  }
}
