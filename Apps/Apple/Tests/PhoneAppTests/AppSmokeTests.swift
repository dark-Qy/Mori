import Domain
import XCTest

@testable import WatchCompanion

final class AppSmokeTests: XCTestCase {
  func testAppEntryPointIsLinked() {
    XCTAssertNotNil(WatchCompanionApp.self as Any.Type)
  }

  func testNoLaunchArgumentUsesNeutralLiveMode() {
    let model = PhonePresentationModel.initial(arguments: ["WatchCompanion"])

    XCTAssertTrue(model.isLive)
    XCTAssertNil(model.mockScenario)
    XCTAssertEqual(model.metrics.first(where: { $0.id == "activity" })?.value, "--")
    XCTAssertTrue(model.dataExplanation.contains("尚无可用 HealthKit 数据"))
  }

  func testMockModeRequiresUITestingAndAllowlistedScenario() {
    let model = PhonePresentationModel.initial(
      arguments: ["WatchCompanion", "-UITesting", "--mock-scenario=health_normal"]
    )

    XCTAssertEqual(model.mockScenario?.id, "health_normal")
    XCTAssertEqual(model.metrics.first(where: { $0.id == "activity" })?.value, "3.2k")
  }

  func testMockArgumentWithoutUITestingIsIgnored() {
    let model = PhonePresentationModel.initial(
      arguments: ["WatchCompanion", "--mock-scenario=health_normal"]
    )

    XCTAssertTrue(model.isLive)
    XCTAssertNil(model.mockScenario)
  }

  func testInvalidMockArgumentFailsClosedInsteadOfReadingHealthKit() {
    let model = PhonePresentationModel.initial(
      arguments: ["WatchCompanion", "-UITesting", "--mock-scenario=typo"]
    )

    XCTAssertFalse(model.isLive)
    XCTAssertNil(model.mockScenario)
    XCTAssertTrue(model.dataExplanation.contains("不访问 Apple 能力"))
  }

  func testLiveHealthValuesDoNotGateTheMainline() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let snapshot = HealthSnapshot(
      capturedAt: now,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .partial,
      sleepMinutes: 390,
      steps: 7_500
    )

    let model = PhonePresentationModel.live(
      companion: CompanionState(),
      health: snapshot,
      trend: nil,
      syncStatus: "已保存"
    )

    XCTAssertEqual(model.metrics.first(where: { $0.id == "recovery" })?.value, "6h30m")
    XCTAssertEqual(model.metrics.first(where: { $0.id == "activity" })?.value, "7.5k")
    XCTAssertEqual(model.questTitle, "点亮营地的第一盏灯")
  }

  func testTrendCopyKeepsMetricMeaning() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let snapshot = HealthSnapshot(
      capturedAt: now,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      sleepMinutes: 390,
      sleepWindowStart: now.addingTimeInterval(-8 * 60 * 60),
      sleepWindowEnd: now,
      steps: 7_500
    )
    let trend = PersonalHealthTrend(
      generatedAt: now,
      recentDays: [],
      observations: [
        observation(.sleepDuration, .belowPersonalRange),
        observation(.steps, .abovePersonalRange),
        observation(.sleepTiming, .abovePersonalRange),
      ],
      baselineWindowDays: 30,
      usableBaselineDayCount: 14
    )

    let model = PhonePresentationModel.live(
      companion: CompanionState(),
      health: snapshot,
      trend: trend,
      syncStatus: "已保存"
    )

    XCTAssertEqual(model.trendSummary, "恢复 少于近期 · 活动 高于近期")
    XCTAssertEqual(model.metrics.first(where: { $0.id == "rhythm" })?.value, "更稳定")
  }

  private func observation(
    _ metric: TrendMetric,
    _ status: PersonalTrendStatus
  ) -> TrendObservation {
    TrendObservation(
      metric: metric,
      status: status,
      currentValue: 1,
      baselineValue: 1,
      relativeDifference: 0,
      knownDayCount: 14,
      explanation: "test fixture"
    )
  }
}
