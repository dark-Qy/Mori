import AppRuntime
import Domain
import UIKit
import XCTest

@testable import WatchCompanion

final class AppSmokeTests: XCTestCase {
  func testAppEntryPointIsLinked() {
    XCTAssertNotNil(WatchCompanionApp.self as Any.Type)
  }

  func testPhonePetInteractionMatchesWatchEventKindsAndCopy() {
    XCTAssertEqual(PhonePetInteraction.touchHead.rawValue, "touch_head")
    XCTAssertEqual(PhonePetInteraction.touchBody.rawValue, "touch_body")
    XCTAssertEqual(PhonePetInteraction.touchHead.statusMessage, "Mori 开心地眨了眨眼")
    XCTAssertEqual(PhonePetInteraction.touchBody.statusMessage, "Mori 转过身回应了你")
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

  func testMock7ActiveBuildsFiveWeeklyMemoriesWithConcreteFactsAndCovers() throws {
    let model = PhonePresentationModel.initial(
      arguments: ["WatchCompanion", "-UITesting", "--mock-scenario=mock7_active"]
    )
    let records = WeeklyMemoryPresentationFactory().makeTimeline(model: model)

    XCTAssertEqual(records.count, 5)
    XCTAssertEqual(Set(records.map(\.bundledCoverAssetName)).count, 5)
    XCTAssertEqual(
      records.map(\.highlight.title),
      [
        "海边散步 · 20 分钟",
        "游泳 · 25 分钟",
        "羽毛球 · 30 分钟",
        "网球 · 40 分钟",
        "足球 · 45 分钟",
      ])
    XCTAssertEqual(
      records.map(\.bundledCoverAssetName),
      [
        "weekly_memory_gentle_walk",
        "weekly_memory_swimming",
        "weekly_memory_badminton",
        "weekly_memory_tennis",
        "weekly_memory_soccer",
      ])
    XCTAssertEqual(
      records.map(\.dateLabel),
      [
        "6月19日—6月25日",
        "6月26日—7月2日",
        "7月3日—7月9日",
        "7月10日—7月16日",
        "7月17日—7月23日",
      ])
    let latest = try XCTUnwrap(records.last)
    XCTAssertEqual(latest.weekID, "mock7_active-2026-07-17-2026-07-23")
    XCTAssertEqual(latest.source, .mock)
    XCTAssertEqual(latest.highlight.title, "足球 · 45 分钟")
    XCTAssertEqual(latest.bundledCoverAssetName, "weekly_memory_soccer")
    XCTAssertEqual(latest.metrics.first(where: { $0.id == "steps" })?.value, "70,900 步")
    XCTAssertEqual(latest.metrics.first(where: { $0.id == "active" })?.value, "353 分钟")
    XCTAssertEqual(latest.metrics.first(where: { $0.id == "sleep" })?.value, "7 小时 30 分")

    let visibleCopy =
      records
      .flatMap { [$0.title, $0.body, $0.accessibilityDescription] }
      .joined(separator: " ")
    for forbidden in ["个人近期", "个人基线", "医学结论", "缺失指标", "Codex image2"] {
      XCTAssertFalse(visibleCopy.contains(forbidden), "Unexpected user-facing copy: \(forbidden)")
    }

    for record in records {
      let cover = try XCTUnwrap(UIImage(named: record.bundledCoverAssetName))
      XCTAssertEqual(cover.size.width, 1_536)
      XCTAssertEqual(cover.size.height, 1_024)
    }
  }

  func testEveryThirtyFiveDayMockBuildsFiveIllustratedWeeks() throws {
    for scenarioID in [
      "mock7_active",
      "mock7_recovery",
      "mock7_rhythm",
      "mock7_sparse",
      "mock7_stable",
    ] {
      let model = PhonePresentationModel.initial(
        arguments: ["WatchCompanion", "-UITesting", "--mock-scenario=\(scenarioID)"]
      )
      let records = WeeklyMemoryPresentationFactory().makeTimeline(model: model)

      XCTAssertEqual(records.count, 5, scenarioID)
      XCTAssertEqual(model.mockScenario?.healthSnapshots.count, 35, scenarioID)
      for record in records {
        XCTAssertNotNil(UIImage(named: record.bundledCoverAssetName), record.bundledCoverAssetName)
      }
    }
  }

  func testRecoveryTimelineUsesRestCoversAndConcreteSleepValues() throws {
    let model = PhonePresentationModel.initial(
      arguments: ["WatchCompanion", "-UITesting", "--mock-scenario=mock7_recovery"]
    )
    let records = WeeklyMemoryPresentationFactory().makeTimeline(model: model)
    let latest = try XCTUnwrap(records.last)

    XCTAssertEqual(records.count, 5)
    XCTAssertTrue(records.allSatisfy { $0.bundledCoverAssetName == "weekly_memory_recovery_rest" })
    XCTAssertEqual(latest.metrics.first(where: { $0.id == "sleep" })?.value, "5 小时 20 分")
    XCTAssertTrue(latest.title.contains("早一点休息"))
    XCTAssertFalse(latest.body.contains("个人近期"))
  }

  @MainActor
  func testDeletedMockWeeklyMemoryStaysDeletedUntilExplicitRetry() async throws {
    let store = PhoneAppStore(
      arguments: ["WatchCompanion", "-UITesting", "--mock-scenario=mock7_active"]
    )
    await store.prepareWeeklyMemory()
    let memory = try XCTUnwrap(store.weeklyMemories.first)
    XCTAssertEqual(store.weeklyMemories.count, 5)

    await store.deleteWeeklyMemory(memory)
    await store.prepareWeeklyMemory()
    XCTAssertEqual(store.weeklyMemories.count, 4)

    await store.prepareWeeklyMemory(force: true)
    XCTAssertEqual(store.weeklyMemories.count, 5)
  }

  @MainActor
  func testWeeklyMemoriesAreIsolatedByMockScenario() {
    let active = PhoneWeeklyMemory(
      record: weeklyArchiveRecord(
        weekID: "mock7_active-2026-07-17-2026-07-23",
        sourceHash: String(repeating: "a", count: 64)
      )
    )
    let recovery = PhoneWeeklyMemory(
      record: weeklyArchiveRecord(
        weekID: "mock7_recovery-2026-07-17-2026-07-23",
        sourceHash: String(repeating: "b", count: 64)
      )
    )

    XCTAssertEqual(
      PhoneAppStore.weeklyMemories([active, recovery], forScenarioID: "mock7_active")
        .map(\.record.weekID),
      [active.record.weekID]
    )
    XCTAssertTrue(
      PhoneAppStore.weeklyMemories([active, recovery], forScenarioID: "health_normal").isEmpty
    )
  }

  @MainActor
  func testWeeklyArchiveKeepsFavoriteWhenWeeklyFactsChange() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = WeeklyMemoryArchiveStore(storageDirectory: directory)

    let first = weeklyArchiveRecord(sourceHash: String(repeating: "a", count: 64))
    _ = try await archive.upsert(first)
    _ = try await archive.setFavorite(true, weekID: first.weekID)
    _ = try await archive.upsert(
      weeklyArchiveRecord(sourceHash: String(repeating: "b", count: 64))
    )
    let loaded = try await archive.load()

    XCTAssertEqual(loaded.first?.record.sourceHash, String(repeating: "b", count: 64))
    XCTAssertEqual(loaded.first?.record.isFavorite, true)
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

  private func weeklyArchiveRecord(
    weekID: String = "2026-W30",
    sourceHash: String
  ) -> ArchivedWeeklyMemory {
    ArchivedWeeklyMemory(
      weekID: weekID,
      sourceHash: sourceHash,
      weekOrdinal: 5,
      weekLabel: "本周回忆",
      dateLabel: "7月20日—7月26日",
      title: "测试回忆",
      body: "只使用确定性事实。",
      metrics: [
        WeeklyMemoryMetric(
          id: "steps",
          label: "本周步数",
          value: "42,000 步",
          accessibilityValue: "42,000 步",
          symbol: "figure.walk"
        )
      ],
      highlight: WeeklyMemoryHighlight(
        title: "海边散步",
        symbol: "figure.walk",
        durationMinutes: nil
      ),
      bundledCoverAssetName: "weekly_memory_gentle_walk",
      source: .mock,
      isFavorite: false,
      isHidden: false,
      createdAt: Date(timeIntervalSince1970: 1_760_000_000),
      accessibilityDescription: "测试回忆。"
    )
  }
}
