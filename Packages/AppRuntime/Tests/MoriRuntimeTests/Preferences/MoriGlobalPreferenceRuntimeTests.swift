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
}
