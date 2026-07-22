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

  func testMockModeRequiresExplicitScenarioArgument() {
    let model = PhonePresentationModel.initial(
      arguments: ["WatchCompanion", "--mock-scenario=recovery_low"]
    )

    XCTAssertEqual(model.mockScenario, .recoveryLow)
    XCTAssertEqual(model.metrics.first(where: { $0.id == "activity" })?.value, "3.1k")
  }

  func testInvalidMockArgumentFailsClosedInsteadOfReadingHealthKit() {
    let model = PhonePresentationModel.initial(
      arguments: ["WatchCompanion", "--mock-scenario=typo"]
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
}
