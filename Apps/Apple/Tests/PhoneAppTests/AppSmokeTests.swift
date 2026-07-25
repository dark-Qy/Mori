import AppRuntime
import Domain
import MoriDomain
import MoriRuntime
import XCTest

@testable import WatchCompanion

@MainActor
final class AppSmokeTests: XCTestCase {
  func testAppEntryPointIsLinked() {
    XCTAssertNotNil(WatchCompanionApp.self as Any.Type)
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
}
