import AppRuntime
import Domain
import MoriDomain
import MoriRuntime
import Persistence
import UIKit
import XCTest

@testable import WatchCompanion

@MainActor
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
    XCTAssertNil(model.stepCount)
    XCTAssertNil(model.sleepMinutes)
    XCTAssertTrue(model.sharedMemories.isEmpty)
  }

  func testInvalidMockArgumentFailsClosed() async {
    let identifier = "invalid-\(UUID().uuidString)"
    let store = PhoneAppStore(
      arguments: [
        "WatchCompanion",
        "-UITesting",
        "--mock-scenario=not_allowlisted",
        "--e2e-storage-id=\(identifier)",
        "--reset-e2e-storage",
        "--e2e-offline-runtime",
      ]
    )

    await store.start()

    XCTAssertFalse(store.model.isLive)
    XCTAssertFalse(store.model.allowsInteraction)
    XCTAssertFalse(store.companionExperienceAvailable)
    XCTAssertEqual(store.activeCoinBalance, 0)
    XCTAssertEqual(store.mockExperience, .empty)
  }

  func testLivePresentationKeepsOnlyExactFacts() {
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
      health: snapshot
    )

    XCTAssertEqual(model.sleepText, "6小时30分")
    XCTAssertEqual(model.stepsText, "7,500步")
    XCTAssertTrue(model.sharedMemories.isEmpty)
    XCTAssertTrue(model.currentFactNarrative.contains("7,500"))
    XCTAssertFalse(model.currentFactNarrative.contains("健康"))
    XCTAssertFalse(model.currentFactNarrative.contains("状态"))
  }

  func testCollectionCatalogMatchesProductAuthority() {
    let presentation = Dictionary(
      uniqueKeysWithValues: PhoneCollectionItem.catalog.map {
        (CosmeticID($0.id), ($0.price, $0.category))
      }
    )

    for item in MoriProductCosmeticCatalog.product.purchasableItems {
      let decorated = presentation[item.id]
      XCTAssertEqual(decorated?.0, item.coinPrice)
      switch item.slot {
      case .outfit:
        XCTAssertEqual(decorated?.1, .clothing)
      case .accessory:
        XCTAssertEqual(decorated?.1, .accessories)
      case .scene:
        XCTAssertEqual(decorated?.1, .scenes)
      }
    }
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

  @MainActor
  func testMockWeeklyWorkoutsReinforceHiddenPersonalizationOnlyOnce() async throws {
    let repository = PersonalizationRepository(
      storage: InMemoryPersonalizationStorage()
    )
    let polisher = CapturingWeeklyMemoryPolisher()
    let store = PhoneAppStore(
      arguments: ["WatchCompanion", "-UITesting", "--mock-scenario=mock7_active"],
      weeklyMemoryPolisher: polisher,
      personalizationRepository: repository
    )

    await store.prepareWeeklyMemory()
    let firstState = try await repository.state()
    XCTAssertEqual(firstState.memories.count, 6)
    XCTAssertEqual(
      Set(firstState.memories.flatMap(\.evidence).map(\.id)).count,
      10
    )
    XCTAssertTrue(polisher.lastPersonality?.themes.contains("racket_sports") == true)
    XCTAssertEqual(firstState.compactProjection.sleepRoutine?.regularity, .steady)

    await store.prepareWeeklyMemory(force: true)
    let secondState = try await repository.state()
    XCTAssertEqual(
      secondState.memories.map(\.reinforcementCount).sorted(),
      [1, 1, 1, 1, 1, 5]
    )
  }

  func testWeeklySleepRoutineUsesOnlyFiveSampleAggregate() throws {
    let stableModel = PhonePresentationModel.initial(
      arguments: ["WatchCompanion", "-UITesting", "--mock-scenario=mock7_stable"]
    )
    let stableRecords = WeeklyMemoryPresentationFactory().makeTimeline(model: stableModel)

    XCTAssertEqual(stableRecords.count, 5)
    for record in stableRecords {
      let routine = try XCTUnwrap(record.facts?.sleepRoutine)
      XCTAssertEqual(routine.sampleCount, 7)
      XCTAssertEqual(routine.band, .from2200To2359)
      XCTAssertEqual(routine.regularity, .steady)
    }

    let rhythmModel = PhonePresentationModel.initial(
      arguments: ["WatchCompanion", "-UITesting", "--mock-scenario=mock7_rhythm"]
    )
    let rhythmRecords = WeeklyMemoryPresentationFactory().makeTimeline(model: rhythmModel)
    XCTAssertEqual(
      rhythmRecords.compactMap(\.facts?.sleepRoutine?.regularity),
      [.varied, .varied, .varied, .varied, .steady]
    )

    let sparseModel = PhonePresentationModel.initial(
      arguments: ["WatchCompanion", "-UITesting", "--mock-scenario=mock7_sparse"]
    )
    let sparseRecords = WeeklyMemoryPresentationFactory().makeTimeline(model: sparseModel)
    XCTAssertEqual(
      sparseRecords.map(\.facts?.sleepRoutine?.sampleCount),
      [nil, 5, nil, 5, 5]
    )
  }

  @MainActor
  func testClearingPersonalizationKeepsToggleAndRestoresMoriCore() async throws {
    let repository = PersonalizationRepository(
      storage: InMemoryPersonalizationStorage()
    )
    try await repository.record(
      .verifiedWorkout(
        activity: .swimming,
        durationMinutes: 40,
        evidenceID: "fixture-swim"
      )
    )
    try await repository.setEnabled(false)
    let store = PhoneAppStore(
      arguments: ["WatchCompanion", "-UITesting", "--mock-scenario=health_normal"],
      personalizationRepository: repository
    )

    await store.start()
    XCTAssertFalse(store.isPersonalizationEnabled)
    await store.clearPersonalization()

    let state = try await repository.state()
    XCTAssertFalse(state.isEnabled)
    XCTAssertTrue(state.memories.isEmpty)
    XCTAssertEqual(state.mori, .original)
    XCTAssertTrue(
      store.personalizationStatus?.contains("回到原来的性格") == true
    )
  }

  func testPersonalityProjectionUsesOnlyGatewayAllowlistedValues() {
    let value = WeeklyMemoryAIPersonalityProjection(
      projection: MoriPersonalityProjection(
        expressionStyle: .playful,
        companionshipRhythm: .lively,
        energy: 0.8,
        playfulness: 0.9,
        brevity: 0.4,
        preferredActivities: [.tennis, .swimming],
        interests: [.quietMoments, .waterSports],
        isPersonalized: true
      )
    )

    XCTAssertEqual(value.voice, "playful")
    XCTAssertEqual(value.pace, "brisk")
    XCTAssertEqual(
      value.themes,
      ["racket_sports", "water_sports", "mindful"]
    )

    let bounded = WeeklyMemoryAIPersonalityProjection(
      projection: MoriPersonalityProjection(
        expressionStyle: .gentle,
        companionshipRhythm: .balanced,
        energy: 0.5,
        playfulness: 0.5,
        brevity: 0.5,
        preferredActivities: [.walking, .soccer, .tennis],
        interests: [.waterSports, .quietMoments],
        isPersonalized: true
      )
    )
    XCTAssertEqual(
      bounded.themes,
      ["outdoor", "exploration", "ball_sports"]
    )
    XCTAssertEqual(bounded.themes.count, 3)
  }

  func testCoarseSleepRoutineOnlySoftensCompanionshipPace() {
    let lateRoutine = WeeklyMemoryAIPersonalityProjection(
      projection: MoriPersonalityProjection(
        expressionStyle: .playful,
        companionshipRhythm: .lively,
        energy: 0.8,
        playfulness: 0.8,
        brevity: 0.4,
        preferredActivities: [],
        interests: [],
        sleepRoutine: SleepRoutineProjection(
          band: .afterMidnight,
          regularity: .steady,
          confidence: 0.8
        ),
        isPersonalized: true
      )
    )
    let noRoutine = WeeklyMemoryAIPersonalityProjection(
      projection: MoriPersonalityProjection(
        expressionStyle: .playful,
        companionshipRhythm: .lively,
        energy: 0.8,
        playfulness: 0.8,
        brevity: 0.4,
        preferredActivities: [],
        interests: [],
        isPersonalized: true
      )
    )

    XCTAssertEqual(lateRoutine.voice, "playful")
    XCTAssertEqual(lateRoutine.pace, "gentle")
    XCTAssertEqual(noRoutine.pace, "brisk")
  }

  func testLiveHealthEvidenceUsesWorkoutIDsAndOnlyAggregatedSleepRoutine() throws {
    let workoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000777")!
    let days = [
      "2025-10-03", "2025-10-04", "2025-10-05", "2025-10-06",
      "2025-10-07", "2025-10-08", "2025-10-09",
    ]
    var history = try days.map {
      try liveSnapshot(day: $0, sleepStartTime: "00:30")
    }
    let latest = try liveSnapshot(
      day: "2025-10-09",
      sleepStartTime: "00:30",
      workouts: [
        WorkoutSummary(
          id: workoutID,
          activity: .tennis,
          startedAt: Date(timeIntervalSince1970: 1_760_000_000),
          durationMinutes: 35
        )
      ]
    )
    history[history.count - 1] = latest

    let values = LivePersonalizationEvidenceFactory().make(
      latestSnapshot: latest,
      history: history,
      excluding: []
    )

    XCTAssertEqual(values.count, 2)
    let workout = try XCTUnwrap(
      values.first {
        $0.evidenceID == "healthkit-workout-\(workoutID.uuidString.lowercased())"
      }
    )
    guard
      case .verifiedWorkout(let activity, let duration, _) = workout.signal
    else {
      return XCTFail("Expected verified workout")
    }
    XCTAssertEqual(activity, .tennis)
    XCTAssertEqual(duration, 35)

    let routine = try XCTUnwrap(
      values.first { $0.evidenceID.hasPrefix("healthkit-sleep-routine-") }
    )
    guard
      case .sleepRoutine(let band, let regularity, let sampleCount, _) = routine.signal
    else {
      return XCTFail("Expected aggregate sleep routine")
    }
    XCTAssertEqual(band, .afterMidnight)
    XCTAssertEqual(regularity, .steady)
    XCTAssertEqual(sampleCount, 7)

    XCTAssertTrue(
      LivePersonalizationEvidenceFactory().make(
        latestSnapshot: latest,
        history: history,
        excluding: Set(values.map(\.evidenceID))
      ).isEmpty
    )
  }

  @MainActor
  func testWeeklyMemoryAIClientUsesTypedContractAndSourceHashCache() async throws {
    WeeklyMemoryURLProtocolStub.reset(source: "upstream")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WeeklyMemoryURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = WeeklyMemoryAIClient(
      configuration: WeeklyMemoryAIRuntimeConfiguration(
        baseURL: try XCTUnwrap(URL(string: "https://social.example"))
      ),
      credentialProvider: StaticWeeklyMemoryCredentialProvider(token: "runtime-token"),
      session: session,
      cache: WeeklyMemoryAICache(storageDirectory: directory)
    )
    let local = weeklyArchiveRecord(sourceHash: String(repeating: "a", count: 64))

    let first = await client.polish([local], personality: .moriCore)
    XCTAssertEqual(first.first?.source, .ai)
    XCTAssertEqual(first.first?.title, "这一周，Mori 想起了海边")
    XCTAssertEqual(WeeklyMemoryURLProtocolStub.recordedRequests().count, 1)

    let captured = try XCTUnwrap(WeeklyMemoryURLProtocolStub.recordedRequests().first)
    XCTAssertEqual(
      captured.url?.path,
      "/ai/v1/weekly-memories/polish"
    )
    XCTAssertEqual(
      captured.value(forHTTPHeaderField: "Authorization"),
      "Bearer runtime-token"
    )
    let body = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: captured.httpBody ?? Data())
        as? [String: Any]
    )
    XCTAssertEqual(
      Set(body.keys),
      [
        "request_id",
        "source_hash",
        "locale",
        "activities",
        "total_steps",
        "active_minutes",
        "average_sleep_minutes",
        "personality",
      ]
    )
    XCTAssertEqual(body["source_hash"] as? String, local.sourceHash)
    XCTAssertEqual(body["total_steps"] as? Int, 42_000)
    XCTAssertTrue(body["active_minutes"] is NSNull)
    XCTAssertTrue(body["average_sleep_minutes"] is NSNull)
    let personality = try XCTUnwrap(body["personality"] as? [String: Any])
    XCTAssertEqual(Set(personality.keys), ["voice", "pace", "themes"])
    XCTAssertEqual(personality["voice"] as? String, "warm")
    XCTAssertEqual(personality["pace"] as? String, "gentle")
    XCTAssertEqual(personality["themes"] as? [String], ["exploration"])

    let second = await client.polish([local], personality: .moriCore)
    XCTAssertEqual(second.first?.source, .ai)
    XCTAssertEqual(WeeklyMemoryURLProtocolStub.recordedRequests().count, 1)

    let changedPersonality = WeeklyMemoryAIPersonalityProjection(
      voice: "playful",
      pace: "brisk",
      themes: ["racket_sports"],
      isPersonalized: true
    )
    let third = await client.polish([local], personality: changedPersonality)
    XCTAssertEqual(third.first?.source, .ai)
    XCTAssertEqual(WeeklyMemoryURLProtocolStub.recordedRequests().count, 2)
    XCTAssertNotEqual(
      third.first?.polishContextHash,
      first.first?.polishContextHash
    )

    let personalizedCoreValues = WeeklyMemoryAIPersonalityProjection(
      voice: "warm",
      pace: "gentle",
      themes: ["exploration"],
      isPersonalized: true
    )
    let fourth = await client.polish(
      [local],
      personality: personalizedCoreValues
    )
    XCTAssertEqual(fourth.first?.source, .ai)
    XCTAssertEqual(WeeklyMemoryURLProtocolStub.recordedRequests().count, 3)
    XCTAssertNotEqual(
      fourth.first?.polishContextHash,
      first.first?.polishContextHash
    )
  }

  @MainActor
  func testWeeklyMemoryAIClientFailsClosedWithoutRuntimeCredential() async throws {
    WeeklyMemoryURLProtocolStub.reset(source: "upstream")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WeeklyMemoryURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = WeeklyMemoryAIClient(
      configuration: WeeklyMemoryAIRuntimeConfiguration(
        baseURL: try XCTUnwrap(URL(string: "https://social.example"))
      ),
      credentialProvider: StaticWeeklyMemoryCredentialProvider(token: nil),
      session: session,
      cache: WeeklyMemoryAICache(storageDirectory: nil)
    )
    let local = weeklyArchiveRecord(sourceHash: String(repeating: "b", count: 64))

    let result = await client.polish([local], personality: .moriCore)

    XCTAssertEqual(result, [local])
    XCTAssertTrue(WeeklyMemoryURLProtocolStub.recordedRequests().isEmpty)
  }

  @MainActor
  func testServerFallbackCannotReplaceLocalDeterministicCopy() async throws {
    WeeklyMemoryURLProtocolStub.reset(source: "fallback")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WeeklyMemoryURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = WeeklyMemoryAIClient(
      configuration: WeeklyMemoryAIRuntimeConfiguration(
        baseURL: try XCTUnwrap(URL(string: "https://social.example"))
      ),
      credentialProvider: StaticWeeklyMemoryCredentialProvider(token: "runtime-token"),
      session: session,
      cache: WeeklyMemoryAICache(storageDirectory: nil)
    )
    let local = weeklyArchiveRecord(sourceHash: String(repeating: "c", count: 64))

    let result = await client.polish([local], personality: .moriCore)

    XCTAssertEqual(result, [local])
    XCTAssertEqual(WeeklyMemoryURLProtocolStub.recordedRequests().count, 1)
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

  #if DEBUG
    func testProductLoopRestartAndDuplicateCommandsStayIdempotent()
      async throws
    {
      let directory = temporaryDirectory()
      let context = try await makeProductLoop(
        scenarioID: "mock1",
        directory: directory
      )
      var snapshot = try await context.runtime.snapshot()
      var projection = PhoneMockExperienceProjection(
        snapshot: snapshot,
        sensingEnabled: true
      )
      XCTAssertEqual(projection.coinBalance, 18)
      XCTAssertEqual(
        projection.ownedItemIDs,
        Set(["default", "spring_meadow_stream"])
      )

      let task = try XCTUnwrap(projection.recommendedTask)
      let firstSettlement = try await context.runtime.completeTask(
        taskID: TaskID(task.id),
        method: .userConfirmed,
        at: Date()
      )
      let replayedSettlement = try await context.runtime.completeTask(
        taskID: TaskID(task.id),
        method: .userConfirmed,
        at: Date()
      )
      XCTAssertTrue(firstSettlement.didRecordReward)
      XCTAssertFalse(replayedSettlement.didRecordCompletion)
      XCTAssertFalse(replayedSettlement.didRecordReward)
      XCTAssertEqual(replayedSettlement.balance, 19)

      let operationID = CollectionOperationID(
        rawValue: "phone.purchase.restart-scarf"
      )
      let firstPurchase = try await context.runtime.purchase(
        cosmeticID: CosmeticID("scarf"),
        operationID: operationID,
        at: Date()
      )
      let replayedPurchase = try await context.runtime.purchase(
        cosmeticID: CosmeticID("scarf"),
        operationID: operationID,
        at: Date()
      )
      XCTAssertTrue(firstPurchase.didRecordPurchase)
      XCTAssertFalse(replayedPurchase.didRecordPurchase)
      XCTAssertEqual(replayedPurchase.balance, 11)

      let reopened = try ProductLoopAppRuntime(
        applicationSupportURL: directory,
        profile: context.profile,
        sensing: context.sensing,
        originDeviceID: "phone"
      )
      _ = try await reopened.activate()
      snapshot = try await reopened.snapshot()
      projection = PhoneMockExperienceProjection(
        snapshot: snapshot,
        sensingEnabled: true
      )
      XCTAssertEqual(projection.coinBalance, 11)
      XCTAssertTrue(projection.ownedItemIDs.contains("scarf"))
      XCTAssertNil(projection.recommendedTask)
    }

    func testPhoneStorePersistsCompleteThenPurchaseAcrossRestart()
      async throws
    {
      let identifier = "restart-\(UUID().uuidString)"
      let first = await makeReadyStore(
        storageID: identifier,
        source: .mock1,
        reset: true
      )
      XCTAssertEqual(first.activeCoinBalance, 18)
      XCTAssertNotNil(first.mockExperience.recommendedTask)

      await first.completeRecommendedTask()
      XCTAssertEqual(first.activeCoinBalance, 19)
      let scarf = try XCTUnwrap(
        PhoneCollectionItem.catalog.first { $0.id == "scarf" }
      )
      await first.purchase(scarf)
      XCTAssertEqual(first.activeCoinBalance, 11)

      let reopened = await makeReadyStore(
        storageID: identifier,
        source: .mock1,
        reset: false
      )
      XCTAssertEqual(reopened.activeCoinBalance, 11)
      XCTAssertTrue(reopened.mockExperience.ownedItemIDs.contains("scarf"))
      XCTAssertNil(reopened.mockExperience.recommendedTask)
    }

    func testResetCreatesFreshMockGenerationWithoutReusingProductState()
      async throws
    {
      let store = await makeReadyStore(
        storageID: "reset-\(UUID().uuidString)",
        source: .mock1,
        reset: true
      )
      await store.completeRecommendedTask()
      XCTAssertEqual(store.activeCoinBalance, 19)

      await store.resetCurrentMockState()

      XCTAssertEqual(store.selectedDataSource, .mock1)
      XCTAssertEqual(store.activeCoinBalance, 18)
      XCTAssertEqual(
        store.mockExperience.ownedItemIDs,
        Set(["default", "spring_meadow_stream"])
      )
      XCTAssertNotNil(store.mockExperience.recommendedTask)
    }

    func testProfileSwitchRaceNeverPublishesOldCollectionState()
      async throws
    {
      let store = await makeReadyStore(
        storageID: "race-\(UUID().uuidString)",
        source: .mock1,
        reset: true
      )
      let scarf = try XCTUnwrap(
        PhoneCollectionItem.catalog.first { $0.id == "scarf" }
      )

      async let purchase: Void = store.purchase(scarf)
      async let switchProfile: Void = store.selectDataSource(.mock2)
      _ = await (purchase, switchProfile)

      XCTAssertEqual(store.selectedDataSource, .mock2)
      XCTAssertEqual(store.activeCoinBalance, 18)
      XCTAssertFalse(store.mockExperience.ownedItemIDs.contains("scarf"))
    }

    func testMockProfileSettingsRemainSeparateAndProfileLocal()
      async throws
    {
      let directory = temporaryDirectory()
      let repository = PhoneMockProfileSettingsRepository(
        fileURL: directory.appendingPathComponent("settings.json")
      )
      let authority = try MoriGlobalPreferenceRuntime(
        storageURL: directory.appendingPathComponent("authority.json"),
        originDeviceID: "phone",
        initialProfileSource: .mock(scenarioID: "mock1")
      )
      let first = try await authority.current().profileScope
      let second = try await authority.selectProfile(
        .mock(scenarioID: "mock2")
      ).profileScope

      _ = try repository.setAppPreferences(
        profile: first,
        proactiveMessagesEnabled: true,
        socialSharingEnabled: true,
        publicPetSocialStateRawValue:
          PublicPetSocialStateV1.greeting.rawValue
      )
      _ = try repository.setConversationMemoryContext(
        profile: first,
        enabled: true
      )

      XCTAssertTrue(
        try repository.settings(profile: first)
          .conversationMemoryContextEnabled
      )
      XCTAssertFalse(
        try repository.settings(profile: second)
          .conversationMemoryContextEnabled
      )
      XCTAssertFalse(
        try repository.settings(profile: second)
          .proactiveMessagesEnabled
      )
      XCTAssertTrue(
        try repository.settings(profile: second)
          .socialSharingEnabled
      )

      _ = try repository.setAppPreferences(
        profile: second,
        proactiveMessagesEnabled: false,
        socialSharingEnabled: false,
        publicPetSocialStateRawValue:
          PublicPetSocialStateV1.greeting.rawValue
      )
      let reloadedRepository = PhoneMockProfileSettingsRepository(
        fileURL: directory.appendingPathComponent("settings.json")
      )
      XCTAssertFalse(
        try reloadedRepository.settings(profile: second)
          .socialSharingEnabled
      )
    }

    func testSensingReconcileRemovesRecommendedTaskAndKeepsLedger()
      async throws
    {
      let directory = temporaryDirectory()
      let context = try await makeProductLoop(
        scenarioID: "mock1",
        directory: directory
      )
      let disabled = CompanionSensingPreference(
        enabled: false,
        epoch: SensingEpoch(
          LamportRevision(
            counter: context.sensing.epoch.revision.counter + 1,
            originDeviceID: "phone"
          )
        )
      )

      _ = try await context.runtime.reconcileSensing(
        disabled,
        effectiveAt: Date()
      )
      let snapshot = try await context.runtime.snapshot()
      let projection = PhoneMockExperienceProjection(
        snapshot: snapshot,
        sensingEnabled: false
      )

      XCTAssertNil(projection.recommendedTask)
      XCTAssertEqual(projection.coinBalance, 18)
      XCTAssertFalse(snapshot.localState.companionSensingEnabled)
      XCTAssertEqual(snapshot.localState.currentSensingEpoch, disabled.epoch)
    }

    func testMockChatAuthorityDoesNotExpandGlobalConsent() async throws {
      let directory = temporaryDirectory()
      let global = try MoriGlobalPreferenceRuntime(
        storageURL: directory.appendingPathComponent("authority.json"),
        originDeviceID: "phone",
        initialProfileSource: .mock(scenarioID: "mock1")
      )
      let profile = try await global.currentChatAuthority().profile
      let local = PhoneMockChatAuthority(
        profile: profile,
        memoryContextEnabled: false
      )

      let localAuthority = await local.setMemoryContext(true)
      let globalAuthority = try await global.currentChatAuthority()
      XCTAssertTrue(localAuthority.memoryContextIsAuthorized)
      XCTAssertFalse(globalAuthority.memoryContextIsAuthorized)
    }

    private func makeReadyStore(
      storageID: String,
      source: CompanionDataSource,
      reset: Bool
    ) async -> PhoneAppStore {
      var arguments = [
        "WatchCompanion",
        "-UITesting",
        "--e2e-storage-id=\(storageID)",
        "--e2e-data-source=\(source.rawValue)",
        "--e2e-offline-runtime",
      ]
      if reset {
        arguments.append("--reset-e2e-storage")
      }
      let store = PhoneAppStore(arguments: arguments)
      await store.start()
      if store.phase == .onboarding {
        await store.completeOnboarding()
      }
      return store
    }

    private func makeProductLoop(
      scenarioID: String,
      directory: URL
    ) async throws -> (
      runtime: ProductLoopAppRuntime,
      profile: RuntimeProfile,
      sensing: CompanionSensingPreference
    ) {
      let global = try MoriGlobalPreferenceRuntime(
        storageURL: directory.appendingPathComponent("authority.json"),
        originDeviceID: "phone",
        initialProfileSource: .mock(scenarioID: scenarioID)
      )
      let projection = try await global.current()
      let authority = try await global.currentChatAuthority()
      let sensing = CompanionSensingPreference(
        enabled: projection.sensingScope.enabled,
        epoch: SensingEpoch(
          LamportRevision(
            counter: projection.sensingScope.epochCounter,
            originDeviceID:
              projection.sensingScope.epochOriginDeviceID
          )
        )
      )
      let runtime = try ProductLoopAppRuntime(
        applicationSupportURL: directory,
        profile: authority.profile,
        sensing: sensing,
        originDeviceID: "phone"
      )
      _ = try await runtime.activate()
      return (runtime, authority.profile, sensing)
    }
  #endif

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
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
      facts: WeeklyMemoryFacts(
        startDate: "2026-07-20",
        endDate: "2026-07-26",
        activityKind: "walking",
        activityDurationMinutes: nil,
        totalSteps: 42_000,
        activeMinutes: nil,
        averageSleepMinutes: nil,
        sleepRoutine: nil
      ),
      polishContextHash: nil,
      bundledCoverAssetName: "weekly_memory_gentle_walk",
      source: .mock,
      isFavorite: false,
      isHidden: false,
      createdAt: Date(timeIntervalSince1970: 1_760_000_000),
      accessibilityDescription: "测试回忆。"
    )
  }

  private func liveSnapshot(
    day: String,
    sleepStartTime: String,
    workouts: [WorkoutSummary] = []
  ) throws -> HealthSnapshot {
    let formatter = ISO8601DateFormatter()
    let capturedAt = try XCTUnwrap(
      formatter.date(from: "\(day)T12:00:00Z")
    )
    let sleepWindowStart = try XCTUnwrap(
      formatter.date(from: "\(day)T\(sleepStartTime):00Z")
    )
    return HealthSnapshot(
      capturedAt: capturedAt,
      timeZoneIdentifier: "UTC",
      localDay: try XCTUnwrap(LocalDay(rawValue: day)),
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .partial,
      sleepWindowStart: sleepWindowStart,
      workouts: workouts
    )
  }
}

@MainActor
private final class CapturingWeeklyMemoryPolisher: WeeklyMemoryPolishing {
  var lastPersonality: WeeklyMemoryAIPersonalityProjection?

  func polish(
    _ records: [ArchivedWeeklyMemory],
    personality: WeeklyMemoryAIPersonalityProjection
  ) async -> [ArchivedWeeklyMemory] {
    lastPersonality = personality
    return records
  }
}

private struct StaticWeeklyMemoryCredentialProvider: WeeklyMemoryAICredentialProviding {
  let token: String?

  func bearerToken() -> String? {
    token
  }
}

private final class WeeklyMemoryURLProtocolStub: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) private static var requests: [URLRequest] = []
  nonisolated(unsafe) private static var responseSource = "upstream"
  private static let lock = NSLock()

  static func reset(source: String) {
    lock.withLock {
      requests = []
      responseSource = source
    }
  }

  static func recordedRequests() -> [URLRequest] {
    lock.withLock { requests }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    do {
      let captured = try Self.capturedRequest(request)
      let source = Self.lock.withLock {
        Self.requests.append(captured)
        return Self.responseSource
      }
      let body = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: captured.httpBody ?? Data())
          as? [String: Any]
      )
      let responseBody: [String: Any] = [
        "request_id": try XCTUnwrap(body["request_id"] as? String),
        "source_hash": try XCTUnwrap(body["source_hash"] as? String),
        "title": "这一周，Mori 想起了海边",
        "body": "走过的脚印和海风，都被 Mori 轻轻收好了。",
        "source": source,
        "fallback_reason": source == "fallback" ? "missing_configuration" : NSNull(),
        "safe": true,
      ]
      let data = try JSONSerialization.data(withJSONObject: responseBody)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(captured.url),
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}

  private static func capturedRequest(_ request: URLRequest) throws -> URLRequest {
    guard request.httpBody == nil, let stream = request.httpBodyStream else {
      return request
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 {
        throw stream.streamError ?? URLError(.cannotDecodeContentData)
      }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    var captured = request
    captured.httpBodyStream = nil
    captured.httpBody = data
    return captured
  }
}
