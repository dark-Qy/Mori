import Foundation
import MoriRuntime
import Testing

@Suite("App-facing global preference runtime")
struct MoriGlobalPreferenceRuntimeTests {
  @Test("Watch choices persist across runtime recreation")
  func choicesPersistAcrossRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MoriGlobalPreferenceRuntimeTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let storageURL = directory.appendingPathComponent("global-authority.json")

    let first = try MoriGlobalPreferenceRuntime(
      storageURL: storageURL,
      originDeviceID: "watch",
      initialProfileSource: .mock(scenarioID: "normal-day")
    )
    _ = try await first.setCompanionSensing(enabled: false)
    _ = try await first.setReminderMode(.gentleHaptic)
    _ = try await first.setQuietHours(
      CompanionQuietHours(startMinute: 23 * 60, endMinute: 8 * 60)
    )

    let reopened = try MoriGlobalPreferenceRuntime(
      storageURL: storageURL,
      originDeviceID: "watch"
    )
    let projection = try await reopened.current()

    #expect(!projection.companionSensingEnabled)
    #expect(projection.profileSource == .mock(scenarioID: "normal-day"))
    #expect(projection.reminderMode == .gentleHaptic)
    #expect(
      projection.quietHours
        == CompanionQuietHours(startMinute: 23 * 60, endMinute: 8 * 60)
    )
  }

  @Test("Profile switches use the same durable authority without mixing source")
  func profileSwitchesRemainIsolated() async throws {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MoriGlobalPreferenceRuntimeTests-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: storageURL) }
    let runtime = try MoriGlobalPreferenceRuntime(
      storageURL: storageURL,
      originDeviceID: "watch",
      initialProfileSource: .mock(scenarioID: "normal-day")
    )

    #expect(
      try await runtime.current().profileSource
        == .mock(scenarioID: "normal-day")
    )
    #expect(
      try await runtime.selectProfile(.real).profileSource == .real
    )
    #expect(
      try await runtime.selectProfile(
        .mock(scenarioID: "fast-walking")
      ).profileSource == .mock(scenarioID: "fast-walking")
    )
  }

  @Test("Mock selection never replaces the one durable real profile")
  func realProfileSurvivesMockRoundTrip() async throws {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MoriGlobalPreferenceRuntimeTests-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: storageURL) }
    let runtime = try MoriGlobalPreferenceRuntime(
      storageURL: storageURL,
      originDeviceID: "phone",
      initialProfileSource: .real
    )

    let initialReal = try await runtime.current()
    _ = try await runtime.selectProfile(
      .mock(scenarioID: "normal-day")
    )
    let restoredReal = try await runtime.selectProfile(.real)

    #expect(restoredReal.profileScope == initialReal.profileScope)
    #expect(
      restoredReal.profileScope.storageKey
        == initialReal.profileScope.storageKey
    )
  }

  @Test("Selecting the same Mock again creates a complete fresh scope")
  func repeatedMockSelectionCreatesFreshScope() async throws {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MoriGlobalPreferenceRuntimeTests-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: storageURL) }
    let runtime = try MoriGlobalPreferenceRuntime(
      storageURL: storageURL,
      originDeviceID: "phone",
      initialProfileSource: .mock(scenarioID: "normal-day")
    )

    let first = try await runtime.current()
    let second = try await runtime.selectProfile(
      .mock(scenarioID: "normal-day")
    )

    #expect(first.profileScope.isMock)
    #expect(second.profileScope.isMock)
    #expect(first.profileScope.mockScenarioID == "normal-day")
    #expect(second.profileScope.mockScenarioID == "normal-day")
    #expect(first.profileScope != second.profileScope)
    #expect(first.profileScope.storageKey != second.profileScope.storageKey)
    #expect(
      first.profileScope.profileEpochCounter
        < second.profileScope.profileEpochCounter
    )
  }

  @Test("Equal quiet-hour boundaries fail closed without mutating state")
  func equalQuietHourBoundariesAreRejected() async throws {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MoriGlobalPreferenceRuntimeTests-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: storageURL) }
    let runtime = try MoriGlobalPreferenceRuntime(
      storageURL: storageURL,
      originDeviceID: "watch"
    )

    await #expect(
      throws: MoriGlobalPreferenceRuntimeError.invalidQuietHours
    ) {
      try await runtime.setQuietHours(
        CompanionQuietHours(startMinute: 22 * 60, endMinute: 22 * 60)
      )
    }
    #expect(
      try await runtime.current().quietHours
        == CompanionQuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
    )
  }

  @Test("Sensing changes publish a fresh epoch and explicit state")
  func sensingChangesPublishFreshEpoch() async throws {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MoriGlobalPreferenceRuntimeTests-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: storageURL) }
    let runtime = try MoriGlobalPreferenceRuntime(
      storageURL: storageURL,
      originDeviceID: "phone"
    )

    let first = try await runtime.current().sensingScope
    let disabled = try await runtime.setCompanionSensing(
      enabled: false
    ).sensingScope
    let enabledAgain = try await runtime.setCompanionSensing(
      enabled: true
    ).sensingScope

    #expect(first.enabled)
    #expect(!disabled.enabled)
    #expect(enabledAgain.enabled)
    #expect(first.epochCounter < disabled.epochCounter)
    #expect(disabled.epochCounter < enabledAgain.epochCounter)
  }

  @Test("Global deletion installs a fresh content-free authority fence")
  func deletionInstallsFreshFence() async throws {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MoriGlobalPreferenceRuntimeTests-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: storageURL) }
    let runtime = try MoriGlobalPreferenceRuntime(
      storageURL: storageURL,
      originDeviceID: "phone",
      initialProfileSource: .mock(scenarioID: "normal-day")
    )
    _ = try await runtime.setReminderMode(.gentleHaptic)
    _ = try await runtime.setQuietHours(
      CompanionQuietHours(startMinute: 23 * 60, endMinute: 8 * 60)
    )
    let before = try await runtime.current()

    await #expect(
      throws: MoriGlobalPreferenceRuntimeError.rejectedPreference
    ) {
      _ = try await runtime.deleteAllData(
        expectedProfileScope: before.profileScope,
        requestID: "baseline"
      )
    }
    await #expect(
      throws: MoriGlobalPreferenceRuntimeError.rejectedPreference
    ) {
      _ = try await runtime.deleteAllData(
        expectedProfileScope: before.profileScope,
        requestID: "mock-baseline-\(String(repeating: "a", count: 64))"
      )
    }

    let deleted = try await runtime.deleteAllData(
      expectedProfileScope: before.profileScope,
      requestID: "delete-test-request"
    )
    let replay = try await runtime.deleteAllData(
      expectedProfileScope: before.profileScope,
      requestID: "delete-test-request"
    )

    #expect(deleted.profileSource == .real)
    #expect(!deleted.profileScope.isMock)
    #expect(deleted.profileScope.deletionRequestID == "delete-test-request")
    #expect(
      deleted.profileScope.deletionEpochCounter
        > before.profileScope.deletionEpochCounter
    )
    #expect(!deleted.companionSensingEnabled)
    #expect(deleted.reminderMode == .wristRaise)
    #expect(
      deleted.quietHours
        == CompanionQuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
    )
    #expect(replay == deleted)

    let selectedRealAgain = try await runtime.selectProfile(.real)
    #expect(selectedRealAgain.profileScope == deleted.profileScope)

    let postDeletionMock = try await runtime.selectProfile(
      .mock(scenarioID: "normal-day")
    )
    #expect(
      postDeletionMock.profileScope.deletionRequestID
        == deleted.profileScope.deletionRequestID
    )
    #expect(
      postDeletionMock.profileScope.deletionEpochCounter
        == deleted.profileScope.deletionEpochCounter
    )
    #expect(
      postDeletionMock.profileScope.deletionEpochOriginDeviceID
        == deleted.profileScope.deletionEpochOriginDeviceID
    )

    let realAfterMock = try await runtime.selectProfile(.real)
    #expect(
      realAfterMock.profileScope.deletionRequestID
        == deleted.profileScope.deletionRequestID
    )
    #expect(
      realAfterMock.profileScope.deletionEpochCounter
        == deleted.profileScope.deletionEpochCounter
    )
    #expect(
      realAfterMock.profileScope.deletionEpochOriginDeviceID
        == deleted.profileScope.deletionEpochOriginDeviceID
    )
    #expect(realAfterMock.profileScope.storageKey != before.profileScope.storageKey)
  }

  @Test("Phone-authored conversation consents persist independently")
  func conversationConsentPersists() async throws {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MoriGlobalPreferenceRuntimeTests-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: storageURL) }
    let runtime = try MoriGlobalPreferenceRuntime(
      storageURL: storageURL,
      originDeviceID: "phone",
      initialProfileSource: .real
    )

    let remote = try await runtime.setConsent(
      .remoteChat,
      enabled: true
    )
    #expect(remote.remoteChatIsAuthorized)
    #expect(!remote.memoryContextIsAuthorized)

    let memory = try await runtime.setConsent(
      .memoryContext,
      enabled: true
    )
    #expect(memory.remoteChatIsAuthorized)
    #expect(memory.memoryContextIsAuthorized)

    let reopened = try MoriGlobalPreferenceRuntime(
      storageURL: storageURL,
      originDeviceID: "phone"
    )
    let persisted = try await reopened.currentChatAuthority()
    #expect(persisted.remoteChatIsAuthorized)
    #expect(persisted.memoryContextIsAuthorized)

    let revokedMemory = try await reopened.setConsent(
      .memoryContext,
      enabled: false
    )
    #expect(revokedMemory.remoteChatIsAuthorized)
    #expect(!revokedMemory.memoryContextIsAuthorized)
  }

  @Test("Watch cannot expand Chat consent and old disclosure versions fail")
  func conversationConsentExpansionIsPhoneOnly() async throws {
    let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MoriGlobalPreferenceRuntimeTests-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: storageURL) }
    let watch = try MoriGlobalPreferenceRuntime(
      storageURL: storageURL,
      originDeviceID: "watch",
      initialProfileSource: .real
    )

    await #expect(
      throws:
        MoriGlobalPreferenceRuntimeError.consentExpansionRequiresPhone
    ) {
      _ = try await watch.setConsent(.remoteChat, enabled: true)
    }

    let phoneURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MoriGlobalPreferenceRuntimeTests-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: phoneURL) }
    let phone = try MoriGlobalPreferenceRuntime(
      storageURL: phoneURL,
      originDeviceID: "phone",
      initialProfileSource: .real
    )
    await #expect(
      throws: MoriGlobalPreferenceRuntimeError.invalidDisclosureVersion
    ) {
      _ = try await phone.setConsent(
        .remoteChat,
        enabled: true,
        disclosureVersion: 0
      )
    }
    #expect(
      !(try await phone.currentChatAuthority().remoteChatIsAuthorized)
    )
  }
}
