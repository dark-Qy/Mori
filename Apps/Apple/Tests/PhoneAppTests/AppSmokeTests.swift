import AppRuntime
import Domain
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

  func testMockModeRequiresUITestingAndAllowlistedScenario() {
    let model = PhonePresentationModel.initial(
      arguments: [
        "WatchCompanion", "-UITesting", "--mock-scenario=mock1",
      ]
    )

    XCTAssertEqual(model.mockScenario?.id, "mock1")
    XCTAssertEqual(model.stepCount, 3_250)
    XCTAssertEqual(model.sleepMinutes, 450)
    XCTAssertEqual(model.initialScreen, .mori)
  }

  func testMockArgumentWithoutUITestingIsIgnored() {
    let model = PhonePresentationModel.initial(
      arguments: ["WatchCompanion", "--mock-scenario=mock1"]
    )

    XCTAssertTrue(model.isLive)
    XCTAssertNil(model.mockScenario)
  }

  func testInvalidMockArgumentFailsClosed() {
    let model = PhonePresentationModel.initial(
      arguments: [
        "WatchCompanion", "-UITesting", "--mock-scenario=not_allowlisted",
      ]
    )

    XCTAssertFalse(model.isLive)
    XCTAssertFalse(model.allowsInteraction)
    XCTAssertNil(model.mockScenario)
    XCTAssertNil(model.stepCount)
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

  func testCollectionPricesUseOneCoinAsMinimumUnit() {
    let prices = PhoneCollectionItem.catalog.map(\.price)

    XCTAssertTrue(prices.allSatisfy { $0 >= 0 })
    XCTAssertTrue(prices.filter { $0 > 0 }.allSatisfy { $0 >= 1 })
    XCTAssertEqual(
      Set(prices),
      Set([0, 4, 8, 12, 50])
    )
  }

  func testRecommendedTaskRequiresSensingAndAConfirmableMockEvent() async throws {
    let model = PhonePresentationModel.initial(
      arguments: [
        "WatchCompanion", "-UITesting", "--mock-scenario=mock1",
      ]
    )
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let authority = try MoriGlobalPreferenceRuntime(
      storageURL: directory.appendingPathComponent("authority.json"),
      originDeviceID: "phone",
      initialProfileSource: .mock(scenarioID: "mock1")
    )
    let enabledSensing = try await authority.current().sensingScope
    XCTAssertNil(
      model.recommendedTaskCandidate(sensingScope: nil)
    )
    let task = try XCTUnwrap(
      model.recommendedTaskCandidate(sensingScope: enabledSensing)
    )
    XCTAssertEqual(task.scenarioID, "mock1")
    XCTAssertTrue(task.sourceEventID.contains("steps-3250"))
    XCTAssertEqual(task.cooldownKey, "reflect-walk-summary")
    XCTAssertEqual(task.reward, 1)
    XCTAssertTrue(task.isValid)
    let disabledSensing =
      try await authority.setCompanionSensing(enabled: false).sensingScope
    XCTAssertNil(
      model.recommendedTaskCandidate(sensingScope: disabledSensing)
    )
    XCTAssertNil(
      PhonePresentationModel.liveNoData()
        .recommendedTaskCandidate(sensingScope: enabledSensing)
    )
  }

  #if DEBUG
    func testMockRepositorySettlesAndPurchasesAtMostOnce() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let repository = PhoneMockExperienceRepository(
        fileURL: directory.appendingPathComponent("experience.json")
      )
      let context = try await makeMockContext(
        scenarioID: "mock1",
        directory: directory
      )
      let profile = context.profileScope
      let sensing = context.sensingScope
      let task = try XCTUnwrap(
        PhonePresentationModel.initial(
          arguments: [
            "WatchCompanion", "-UITesting", "--mock-scenario=mock1",
          ]
        ).recommendedTaskCandidate(sensingScope: sensing)
      )
      _ = try repository.prepareRecommendedTask(
        profile: profile,
        sensing: sensing,
        candidate: task
      )

      let first = try repository.settleTask(
        profile: profile,
        sensing: sensing,
        taskID: task.id
      )
      let replay = try repository.settleTask(
        profile: profile,
        sensing: sensing,
        taskID: task.id
      )
      XCTAssertFalse(first.wasAlreadySettled)
      XCTAssertTrue(replay.wasAlreadySettled)
      XCTAssertEqual(replay.projection.coinBalance, 19)

      guard
        case .purchased(let purchased) = try repository.purchase(
          profile: profile,
          itemID: "scarf"
        )
      else {
        return XCTFail("Expected first purchase")
      }
      guard
        case .alreadyOwned(let replayed) = try repository.purchase(
          profile: profile,
          itemID: "scarf"
        )
      else {
        return XCTFail("Expected idempotent purchase replay")
      }
      XCTAssertEqual(purchased.coinBalance, 11)
      XCTAssertEqual(replayed.coinBalance, 11)
    }

    func testMockRepositoryKeepsProfilesIsolated() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let repository = PhoneMockExperienceRepository(
        fileURL: directory.appendingPathComponent("experience.json")
      )
      let authority = try MoriGlobalPreferenceRuntime(
        storageURL: directory.appendingPathComponent("authority.json"),
        originDeviceID: "phone",
        initialProfileSource: .mock(scenarioID: "mock1")
      )
      let mock1Context = try await authority.current()
      let mock1Profile = mock1Context.profileScope
      let sensing = mock1Context.sensingScope
      let mock2Profile = try await authority.selectProfile(
        .mock(scenarioID: "mock2")
      ).profileScope
      let task = try XCTUnwrap(
        PhonePresentationModel.initial(
          arguments: [
            "WatchCompanion", "-UITesting", "--mock-scenario=mock1",
          ]
        ).recommendedTaskCandidate(sensingScope: sensing)
      )
      _ = try repository.prepareRecommendedTask(
        profile: mock1Profile,
        sensing: sensing,
        candidate: task
      )

      _ = try repository.settleTask(
        profile: mock1Profile,
        sensing: sensing,
        taskID: task.id
      )
      let mock1 = try repository.projection(profile: mock1Profile)
      let mock2 = try repository.projection(profile: mock2Profile)

      XCTAssertEqual(mock1.coinBalance, 19)
      XCTAssertEqual(mock2.coinBalance, 18)
    }

    func testMockRepositoryScrubsDeprecatedConversationFieldsOnLoad()
      async throws
    {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let fileURL = directory.appendingPathComponent("experience.json")
      let profile = try await makeMockProfile(
        scenarioID: "mock1",
        directory: directory
      )
      var projection = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: JSONEncoder().encode(PhoneMockExperienceProjection.initial)
        ) as? [String: Any]
      )
      projection["conversation"] = [
        [
          "id": UUID().uuidString,
          "role": "user",
          "text": "deprecated private text",
        ]
      ]
      projection["usesMemoryContext"] = true
      let snapshot: [String: Any] = [
        "schemaVersion": 1,
        "profiles": [profile.storageKey: projection],
      ]
      try JSONSerialization.data(
        withJSONObject: snapshot,
        options: [.sortedKeys]
      ).write(to: fileURL, options: [.atomic])

      let repository = PhoneMockExperienceRepository(fileURL: fileURL)
      _ = try repository.projection(profile: profile)

      let rewritten = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: Data(contentsOf: fileURL)
        ) as? [String: Any]
      )
      let profiles = try XCTUnwrap(
        rewritten["profiles"] as? [String: Any]
      )
      let scrubbed = try XCTUnwrap(
        profiles[profile.storageKey] as? [String: Any]
      )
      XCTAssertNil(scrubbed["conversation"])
      XCTAssertNil(scrubbed["usesMemoryContext"])
    }

    func testRepeatedSelectionOfSameScenarioUsesFreshExperience() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let repository = PhoneMockExperienceRepository(
        fileURL: directory.appendingPathComponent("experience.json")
      )
      let authority = try MoriGlobalPreferenceRuntime(
        storageURL: directory.appendingPathComponent("authority.json"),
        originDeviceID: "phone",
        initialProfileSource: .mock(scenarioID: "mock1")
      )
      let firstContext = try await authority.current()
      let firstProfile = firstContext.profileScope
      let sensing = firstContext.sensingScope
      let secondProfile = try await authority.selectProfile(
        .mock(scenarioID: "mock1")
      ).profileScope
      let task = try XCTUnwrap(
        PhonePresentationModel.initial(
          arguments: [
            "WatchCompanion", "-UITesting", "--mock-scenario=mock1",
          ]
        ).recommendedTaskCandidate(sensingScope: sensing)
      )
      _ = try repository.prepareRecommendedTask(
        profile: firstProfile,
        sensing: sensing,
        candidate: task
      )
      _ = try repository.settleTask(
        profile: firstProfile,
        sensing: sensing,
        taskID: task.id
      )
      let firstExperience = try repository.projection(
        profile: firstProfile
      )
      let secondExperience = try repository.projection(
        profile: secondProfile
      )

      XCTAssertNotEqual(firstProfile, secondProfile)
      XCTAssertEqual(firstExperience.coinBalance, 19)
      XCTAssertEqual(secondExperience.coinBalance, 18)
    }

    func testRepositoryUsesCatalogPriceInsteadOfCallerInput() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let repository = PhoneMockExperienceRepository(
        fileURL: directory.appendingPathComponent("experience.json")
      )
      let profile = try await makeMockProfile(
        scenarioID: "mock1",
        directory: directory
      )

      guard
        case .purchased(let projection) = try repository.purchase(
          profile: profile,
          itemID: "scarf"
        )
      else {
        return XCTFail("Expected catalog purchase")
      }
      XCTAssertEqual(projection.coinBalance, 10)
    }

    func testTaskGenerationUsesOneSourceEventAndTypeCooldown() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let repository = PhoneMockExperienceRepository(
        fileURL: directory.appendingPathComponent("experience.json")
      )
      let context = try await makeMockContext(
        scenarioID: "mock1",
        directory: directory
      )
      let profile = context.profileScope
      let sensing = context.sensingScope
      let first = try XCTUnwrap(
        PhonePresentationModel.initial(
          arguments: [
            "WatchCompanion", "-UITesting", "--mock-scenario=mock1",
          ]
        ).recommendedTaskCandidate(sensingScope: sensing)
      )
      _ = try repository.prepareRecommendedTask(
        profile: profile,
        sensing: sensing,
        candidate: first
      )
      _ = try repository.settleTask(
        profile: profile,
        sensing: sensing,
        taskID: first.id
      )

      let duringCooldown = PhoneRecommendedTask(
        id: "\(first.id).second",
        scenarioID: first.scenarioID,
        sourceEventID: "\(first.sourceEventID).second",
        cooldownKey: first.cooldownKey,
        kind: first.kind,
        sensingEpochCounter: sensing.epochCounter,
        sensingEpochOriginDeviceID: sensing.epochOriginDeviceID,
        issuedAt: first.issuedAt.addingTimeInterval(60 * 60),
        cooldownDuration: first.cooldownDuration,
        reward: first.reward
      )
      let blocked = try repository.prepareRecommendedTask(
        profile: profile,
        sensing: sensing,
        candidate: duringCooldown
      )
      XCTAssertNil(blocked.recommendedTask)

      let afterCooldown = PhoneRecommendedTask(
        id: "\(first.id).third",
        scenarioID: first.scenarioID,
        sourceEventID: "\(first.sourceEventID).third",
        cooldownKey: first.cooldownKey,
        kind: first.kind,
        sensingEpochCounter: sensing.epochCounter,
        sensingEpochOriginDeviceID: sensing.epochOriginDeviceID,
        issuedAt: first.issuedAt.addingTimeInterval(7 * 60 * 60),
        cooldownDuration: first.cooldownDuration,
        reward: first.reward
      )
      let issued = try repository.prepareRecommendedTask(
        profile: profile,
        sensing: sensing,
        candidate: afterCooldown
      )
      XCTAssertEqual(issued.recommendedTask, afterCooldown)
      XCTAssertEqual(
        issued.generatedTaskSourceEventIDs,
        Set([first.sourceEventID, afterCooldown.sourceEventID])
      )
    }

    func testSensingRevocationHidesAndRejectsOutstandingTask() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let repository = PhoneMockExperienceRepository(
        fileURL: directory.appendingPathComponent("experience.json")
      )
      let authority = try MoriGlobalPreferenceRuntime(
        storageURL: directory.appendingPathComponent("authority.json"),
        originDeviceID: "phone",
        initialProfileSource: .mock(scenarioID: "mock1")
      )
      let enabledContext = try await authority.current()
      let task = try XCTUnwrap(
        PhonePresentationModel.initial(
          arguments: [
            "WatchCompanion", "-UITesting", "--mock-scenario=mock1",
          ]
        ).recommendedTaskCandidate(sensingScope: enabledContext.sensingScope)
      )
      _ = try repository.prepareRecommendedTask(
        profile: enabledContext.profileScope,
        sensing: enabledContext.sensingScope,
        candidate: task
      )

      let disabledContext =
        try await authority.setCompanionSensing(enabled: false)

      // Production settlements revalidate inside the authority actor. The
      // repository still contains the old authorization at this point, so
      // this covers the late-callback window before disabled preparation.
      await assertThrowsErrorAsync {
        _ =
          try await authority.performAuthorizedSensingMutation(
            profileScope: enabledContext.profileScope,
            sensingScope: enabledContext.sensingScope
          ) {
            try repository.settleTask(
              profile: enabledContext.profileScope,
              sensing: enabledContext.sensingScope,
              taskID: task.id
            )
          }
      }

      let revoked = try repository.prepareRecommendedTask(
        profile: disabledContext.profileScope,
        sensing: disabledContext.sensingScope,
        candidate: nil
      )

      XCTAssertNil(revoked.recommendedTask)
      await assertThrowsErrorAsync {
        _ = try repository.settleTask(
          profile: disabledContext.profileScope,
          sensing: disabledContext.sensingScope,
          taskID: task.id
        )
      }
      await assertThrowsErrorAsync {
        _ = try repository.settleTask(
          profile: disabledContext.profileScope,
          sensing: enabledContext.sensingScope,
          taskID: task.id
        )
      }
      let afterRevocation = try repository.projection(
        profile: disabledContext.profileScope
      )
      XCTAssertEqual(afterRevocation.coinBalance, 18)
    }

    func testMockPreferencesStayInsideSelectedProfileGeneration() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let repository = PhoneMockExperienceRepository(
        fileURL: directory.appendingPathComponent("experience.json")
      )
      let authority = try MoriGlobalPreferenceRuntime(
        storageURL: directory.appendingPathComponent("authority.json"),
        originDeviceID: "phone",
        initialProfileSource: .mock(scenarioID: "mock1")
      )
      let first = try await authority.current().profileScope
      let second = try await authority.selectProfile(
        .mock(scenarioID: "mock1")
      ).profileScope

      _ = try repository.setAppPreferences(
        profile: first,
        proactiveMessagesEnabled: true,
        socialSharingEnabled: true,
        publicPetSocialStateRawValue: "greeting"
      )
      let firstProjection = try repository.projection(profile: first)
      let secondProjection = try repository.projection(profile: second)

      XCTAssertEqual(firstProjection.proactiveMessagesEnabled, true)
      XCTAssertEqual(firstProjection.socialSharingEnabled, true)
      XCTAssertNil(secondProjection.proactiveMessagesEnabled)
      XCTAssertNil(secondProjection.socialSharingEnabled)
      XCTAssertFalse(
        secondProjection.appPreferenceState.proactiveMessagesEnabled
      )
      XCTAssertFalse(secondProjection.appPreferenceState.socialSharingEnabled)
      XCTAssertEqual(
        secondProjection.appPreferenceState.publicPetSocialStateRawValue,
        PublicPetSocialStateV1.greeting.rawValue
      )
    }

    func testMockConversationMemoryConsentIsProfileLocal() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let repository = PhoneMockExperienceRepository(
        fileURL: directory.appendingPathComponent("experience.json")
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

      let firstProjection =
        try repository.setConversationMemoryContext(
          profile: first,
          enabled: true
        )
      let secondProjection = try repository.projection(profile: second)

      XCTAssertEqual(
        firstProjection.conversationMemoryContextEnabled,
        true
      )
      XCTAssertNil(secondProjection.conversationMemoryContextEnabled)
      let globalAuthority = try await authority.currentChatAuthority()
      XCTAssertFalse(globalAuthority.memoryContextIsAuthorized)
    }

    func testMockChatAuthorityDoesNotExpandGlobalConsent() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
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

    func testClothingAndAccessoryEquipmentRemainIndependent() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let repository = PhoneMockExperienceRepository(
        fileURL: directory.appendingPathComponent("experience.json")
      )
      let profile = try await makeMockProfile(
        scenarioID: "mock1",
        directory: directory
      )
      _ = try repository.purchase(profile: profile, itemID: "scarf")
      _ = try repository.purchase(profile: profile, itemID: "leaf")
      _ = try repository.equip(profile: profile, itemID: "scarf")
      let equipped = try repository.equip(
        profile: profile,
        itemID: "leaf"
      )

      XCTAssertEqual(equipped.equippedItemID, "scarf")
      XCTAssertEqual(equipped.equippedAccessoryID, "leaf")
    }

    func testGlobalMockDeletionClearsEveryProfileGeneration() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let repository = PhoneMockExperienceRepository(
        fileURL: directory.appendingPathComponent("experience.json")
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
      _ = try repository.purchase(profile: first, itemID: "scarf")
      _ = try repository.purchase(profile: second, itemID: "leaf")

      let deletion = try await authority.deleteAllData(
        expectedProfileScope: second,
        requestID: "delete-phone-mock-test"
      )
      try repository.deleteAll(fence: deletion.profileScope)

      await assertThrowsErrorAsync {
        _ = try repository.projection(profile: first)
      }
      await assertThrowsErrorAsync {
        _ = try repository.projection(profile: second)
      }
      let postDeletionProfile = try await authority.selectProfile(
        .mock(scenarioID: "mock3")
      ).profileScope
      let postDeletionExperience = try repository.projection(
        profile: postDeletionProfile
      )
      XCTAssertEqual(postDeletionExperience, .initial)
    }

    private func makeMockProfile(
      scenarioID: String,
      directory: URL
    ) async throws -> MoriGlobalProfileScope {
      try await makeMockContext(
        scenarioID: scenarioID,
        directory: directory
      ).profileScope
    }

    private func makeMockContext(
      scenarioID: String,
      directory: URL
    ) async throws -> MoriGlobalPreferenceProjection {
      let authority = try MoriGlobalPreferenceRuntime(
        storageURL: directory.appendingPathComponent(
          "authority-\(UUID().uuidString).json"
        ),
        originDeviceID: "phone",
        initialProfileSource: .mock(scenarioID: scenarioID)
      )
      return try await authority.current()
    }

    private func assertThrowsErrorAsync(
      _ expression: () async throws -> Void,
      file: StaticString = #filePath,
      line: UInt = #line
    ) async {
      do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
      } catch {
        // Expected.
      }
    }
  #endif
}
