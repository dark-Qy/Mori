import Foundation

public enum PersonalTrendStatus: String, Codable, Equatable, Sendable {
  case belowPersonalRange
  case withinPersonalRange
  case abovePersonalRange
  case insufficientData
}

public enum TrendMetric: String, Codable, CaseIterable, Sendable {
  case sleepDuration
  case steps
  case activeMinutes
  case sleepTiming
}

public struct TrendObservation: Codable, Equatable, Sendable {
  public var metric: TrendMetric
  public var status: PersonalTrendStatus
  public var currentValue: Double?
  public var baselineValue: Double?
  public var relativeDifference: Double?
  public var knownDayCount: Int
  public var explanation: String

  public init(
    metric: TrendMetric,
    status: PersonalTrendStatus,
    currentValue: Double?,
    baselineValue: Double?,
    relativeDifference: Double?,
    knownDayCount: Int,
    explanation: String
  ) {
    self.metric = metric
    self.status = status
    self.currentValue = currentValue
    self.baselineValue = baselineValue
    self.relativeDifference = relativeDifference
    self.knownDayCount = max(0, knownDayCount)
    self.explanation = explanation
  }
}

public struct DailyTrendPoint: Codable, Equatable, Sendable {
  public var day: LocalDay
  public var sleepMinutes: Int?
  public var steps: Int?
  public var activeMinutes: Int?

  public init(
    day: LocalDay,
    sleepMinutes: Int?,
    steps: Int?,
    activeMinutes: Int?
  ) {
    self.day = day
    self.sleepMinutes = sleepMinutes
    self.steps = steps
    self.activeMinutes = activeMinutes
  }
}

public struct PersonalHealthTrend: Codable, Equatable, Sendable {
  public var generatedAt: Date
  public var recentDays: [DailyTrendPoint]
  public var observations: [TrendObservation]
  public var baselineWindowDays: Int
  public var usableBaselineDayCount: Int

  public init(
    generatedAt: Date,
    recentDays: [DailyTrendPoint],
    observations: [TrendObservation],
    baselineWindowDays: Int,
    usableBaselineDayCount: Int
  ) {
    self.generatedAt = generatedAt
    self.recentDays = recentDays
    self.observations = observations
    self.baselineWindowDays = max(1, baselineWindowDays)
    self.usableBaselineDayCount = max(0, usableBaselineDayCount)
  }
}
