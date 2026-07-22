import Domain
import Foundation

public struct PersonalTrendConfiguration: Codable, Equatable, Sendable {
  public var recentWindowDays: Int
  public var baselineWindowDays: Int
  public var minimumBaselineDays: Int
  public var meaningfulRelativeDifference: Double

  public init(
    recentWindowDays: Int = 7,
    baselineWindowDays: Int = 30,
    minimumBaselineDays: Int = 7,
    meaningfulRelativeDifference: Double = 0.15
  ) {
    self.recentWindowDays = max(1, recentWindowDays)
    self.baselineWindowDays = max(1, baselineWindowDays)
    self.minimumBaselineDays = max(2, minimumBaselineDays)
    self.meaningfulRelativeDifference = min(max(meaningfulRelativeDifference, 0.01), 1)
  }
}

/// Compares known values with the user's own history. Missing days are omitted, never converted
/// to zero. The analyzer describes relative context and does not produce medical conclusions.
public struct PersonalTrendAnalyzer: Sendable {
  public var configuration: PersonalTrendConfiguration

  public init(configuration: PersonalTrendConfiguration = PersonalTrendConfiguration()) {
    self.configuration = configuration
  }

  public func analyze(_ snapshots: [HealthSnapshot], at generatedAt: Date) -> PersonalHealthTrend {
    let canonical = canonicalSnapshots(snapshots)
    let recent = Array(canonical.suffix(configuration.recentWindowDays))
    let baseline = Array(canonical.suffix(configuration.baselineWindowDays))

    let recentPoints = recent.map {
      DailyTrendPoint(
        day: $0.localDay,
        sleepMinutes: usable($0) ? $0.sleepMinutes : nil,
        steps: usable($0) ? $0.steps : nil,
        activeMinutes: usable($0) ? $0.activeMinutes : nil
      )
    }
    let observations = [
      observation(
        metric: .sleepDuration,
        recent: recent.compactMap { usable($0) ? $0.sleepMinutes.map(Double.init) : nil },
        baseline: baseline.compactMap { usable($0) ? $0.sleepMinutes.map(Double.init) : nil },
        unit: "minutes of sleep"
      ),
      observation(
        metric: .steps,
        recent: recent.compactMap { usable($0) ? $0.steps.map(Double.init) : nil },
        baseline: baseline.compactMap { usable($0) ? $0.steps.map(Double.init) : nil },
        unit: "steps"
      ),
      observation(
        metric: .activeMinutes,
        recent: recent.compactMap { usable($0) ? $0.activeMinutes.map(Double.init) : nil },
        baseline: baseline.compactMap { usable($0) ? $0.activeMinutes.map(Double.init) : nil },
        unit: "active minutes"
      ),
      sleepTimingObservation(recent: recent, baseline: baseline),
    ]

    return PersonalHealthTrend(
      generatedAt: generatedAt,
      recentDays: recentPoints,
      observations: observations,
      baselineWindowDays: configuration.baselineWindowDays,
      usableBaselineDayCount: baseline.filter(usable).count
    )
  }

  private func canonicalSnapshots(_ snapshots: [HealthSnapshot]) -> [HealthSnapshot] {
    var byDay: [LocalDay: HealthSnapshot] = [:]
    for snapshot in snapshots where snapshot.hasConsistentSettlementDay {
      if let existing = byDay[snapshot.localDay], existing.capturedAt >= snapshot.capturedAt {
        continue
      }
      byDay[snapshot.localDay] = snapshot
    }
    return byDay.values.sorted { $0.localDay < $1.localDay }
  }

  private func usable(_ snapshot: HealthSnapshot) -> Bool {
    snapshot.requestState == .requestCompleted && snapshot.availability != .noData
      && snapshot.hasAnyMetric
  }

  private func observation(
    metric: TrendMetric,
    recent: [Double],
    baseline: [Double],
    unit: String
  ) -> TrendObservation {
    guard
      recent.count >= 2,
      baseline.count >= configuration.minimumBaselineDays,
      let recentAverage = average(recent),
      let baselineAverage = average(baseline),
      baselineAverage > 0
    else {
      return TrendObservation(
        metric: metric,
        status: .insufficientData,
        currentValue: average(recent),
        baselineValue: average(baseline),
        relativeDifference: nil,
        knownDayCount: baseline.count,
        explanation: "Not enough known days to compare \(unit) with a personal baseline."
      )
    }

    let difference = (recentAverage - baselineAverage) / baselineAverage
    let status: PersonalTrendStatus
    if difference <= -configuration.meaningfulRelativeDifference {
      status = .belowPersonalRange
    } else if difference >= configuration.meaningfulRelativeDifference {
      status = .abovePersonalRange
    } else {
      status = .withinPersonalRange
    }
    return TrendObservation(
      metric: metric,
      status: status,
      currentValue: recentAverage,
      baselineValue: baselineAverage,
      relativeDifference: difference,
      knownDayCount: baseline.count,
      explanation: "Recent known \(unit) were compared with this person's available history."
    )
  }

  private func sleepTimingObservation(
    recent: [HealthSnapshot],
    baseline: [HealthSnapshot]
  ) -> TrendObservation {
    let recentMinutes = recent.compactMap(localSleepStartMinute)
    let baselineMinutes = baseline.compactMap(localSleepStartMinute)
    guard
      recentMinutes.count >= 2,
      baselineMinutes.count >= configuration.minimumBaselineDays,
      let recentDeviation = circularMeanDeviation(recentMinutes),
      let baselineDeviation = circularMeanDeviation(baselineMinutes)
    else {
      return TrendObservation(
        metric: .sleepTiming,
        status: .insufficientData,
        currentValue: nil,
        baselineValue: nil,
        relativeDifference: nil,
        knownDayCount: baselineMinutes.count,
        explanation: "Not enough known sleep windows to describe timing consistency."
      )
    }

    let thresholdMinutes = 30.0
    let status: PersonalTrendStatus
    if recentDeviation > baselineDeviation + thresholdMinutes {
      status = .belowPersonalRange
    } else if recentDeviation + thresholdMinutes < baselineDeviation {
      status = .abovePersonalRange
    } else {
      status = .withinPersonalRange
    }
    return TrendObservation(
      metric: .sleepTiming,
      status: status,
      currentValue: recentDeviation,
      baselineValue: baselineDeviation,
      relativeDifference: baselineDeviation > 0
        ? (recentDeviation - baselineDeviation) / baselineDeviation : nil,
      knownDayCount: baselineMinutes.count,
      explanation: "Recent sleep-start consistency was compared with known personal timing."
    )
  }

  private func localSleepStartMinute(_ snapshot: HealthSnapshot) -> Double? {
    guard usable(snapshot), let date = snapshot.sleepWindowStart,
      let timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier)
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.hour, .minute], from: date)
    guard let hour = components.hour, let minute = components.minute else { return nil }
    var result = Double(hour * 60 + minute)
    // Treat early-morning sleep starts as continuing the prior evening.
    if result < 12 * 60 { result += 24 * 60 }
    return result
  }

  private func circularMeanDeviation(_ values: [Double]) -> Double? {
    guard let mean = average(values) else { return nil }
    return average(values.map { abs($0 - mean) })
  }

  private func average(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }
}
