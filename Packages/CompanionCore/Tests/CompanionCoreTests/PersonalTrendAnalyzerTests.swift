import Domain
import Foundation
import Rules
import Testing

@Suite("Personal health trends")
struct PersonalTrendAnalyzerTests {
  private let day: TimeInterval = 86_400

  @Test("Thirty-day baseline and seven-day view use personal known values")
  func baselineAndRecentWindows() {
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    let snapshots = (0..<30).map { index in
      snapshot(
        at: start.addingTimeInterval(Double(index) * day),
        sleep: index >= 23 ? 360 : 480,
        steps: index >= 23 ? 4_000 : 8_000,
        active: index >= 23 ? 15 : 35
      )
    }

    let trend = PersonalTrendAnalyzer().analyze(snapshots, at: start.addingTimeInterval(30 * day))

    #expect(trend.recentDays.count == 7)
    #expect(trend.usableBaselineDayCount == 30)
    #expect(observation(.sleepDuration, in: trend)?.status == .belowPersonalRange)
    #expect(observation(.steps, in: trend)?.status == .belowPersonalRange)
    #expect(observation(.activeMinutes, in: trend)?.status == .belowPersonalRange)
  }

  @Test("Missing metrics stay missing and never become zero")
  func missingDataIsNotZero() {
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    var snapshots = (0..<8).map { index in
      snapshot(at: start.addingTimeInterval(Double(index) * day), sleep: nil, steps: 7_000)
    }
    snapshots.append(
      HealthSnapshot(
        capturedAt: start.addingTimeInterval(9 * day),
        freshness: .noData,
        requestState: .requestCompleted,
        availability: .noData
      )
    )

    let trend = PersonalTrendAnalyzer().analyze(snapshots, at: start.addingTimeInterval(10 * day))
    let sleep = observation(.sleepDuration, in: trend)

    #expect(sleep?.status == .insufficientData)
    #expect(sleep?.currentValue == nil)
    #expect(trend.recentDays.last?.sleepMinutes == nil)
  }

  @Test("Latest snapshot wins for a duplicated local day")
  func latestSnapshotPerDay() {
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    var snapshots = (0..<7).map { index in
      snapshot(at: start.addingTimeInterval(Double(index) * day), sleep: 420, steps: 6_000)
    }
    let duplicateDate = start.addingTimeInterval(6 * day + 3_600)
    snapshots.append(snapshot(at: duplicateDate, sleep: 480, steps: 9_000))

    let trend = PersonalTrendAnalyzer().analyze(snapshots, at: duplicateDate)

    #expect(trend.recentDays.count == 7)
    #expect(trend.recentDays.last?.sleepMinutes == 480)
    #expect(trend.recentDays.last?.steps == 9_000)
  }

  @Test("Sleep timing uses the fixture time zone and describes consistency")
  func timingConsistency() {
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    let offsets = [0, 20, -15, 10, -10, 15, 0, 240, -180, 200, -220, 180, -160, 210]
    let snapshots = offsets.enumerated().map { index, offset in
      let date = start.addingTimeInterval(Double(index) * day)
      return snapshot(
        at: date,
        sleep: 420,
        steps: 7_000,
        sleepStart: date.addingTimeInterval(Double(23 * 3_600 + offset * 60))
      )
    }

    let trend = PersonalTrendAnalyzer().analyze(snapshots, at: start.addingTimeInterval(15 * day))
    let timing = observation(.sleepTiming, in: trend)

    #expect(timing?.knownDayCount == 14)
    #expect(timing?.status != .insufficientData)
  }

  private func snapshot(
    at date: Date,
    sleep: Int?,
    steps: Int?,
    active: Int? = 30,
    sleepStart: Date? = nil
  ) -> HealthSnapshot {
    HealthSnapshot(
      capturedAt: date,
      timeZoneIdentifier: "Asia/Shanghai",
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      sleepMinutes: sleep,
      sleepWindowStart: sleepStart,
      sleepWindowEnd: sleepStart?.addingTimeInterval(7 * 3_600),
      steps: steps,
      activeMinutes: active
    )
  }

  private func observation(_ metric: TrendMetric, in trend: PersonalHealthTrend)
    -> TrendObservation?
  {
    trend.observations.first { $0.metric == metric }
  }
}
