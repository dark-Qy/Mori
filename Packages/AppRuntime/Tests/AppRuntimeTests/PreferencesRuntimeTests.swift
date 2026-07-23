import AppRuntime
import Foundation
import Testing

@Suite("Application preferences")
struct PreferencesRuntimeTests {
  @Test("Consent-gated features start disabled while care summary is the future scope")
  func privacyDefaults() {
    let value = AppPreferences()

    #expect(!value.hasCompletedOnboarding)
    #expect(!value.socialSharingEnabled)
    #expect(value.healthSharingScope == .careSummary)
    #expect(!value.proactiveMessagesEnabled)
    #expect(value.proactiveNotificationConsentVersion == 0)
  }

  @Test("Legacy implicit notification opt-in migrates to disabled")
  func legacyNotificationConsentFailsClosed() throws {
    let legacy = Data(
      """
      {
        "schemaVersion": 1,
        "proactiveMessagesEnabled": true,
        "socialSharingEnabled": false,
        "healthSharingScope": "careSummary",
        "selectedOutfitID": "default",
        "quietHoursStartMinute": 1320,
        "quietHoursEndMinute": 420
      }
      """.utf8
    )

    let decoded = try JSONDecoder().decode(AppPreferences.self, from: legacy)
    #expect(decoded.hasCompletedOnboarding)
    #expect(!decoded.proactiveMessagesEnabled)
    #expect(decoded.proactiveNotificationConsentVersion == 0)
  }

  @Test("Preferences persist across repository instances")
  func roundTrip() async throws {
    let store = InMemoryPreferencesDataStore()
    let first = PreferencesRepository(store: store)
    var value = try await first.load()
    value.hasCompletedOnboarding = true
    value.selectedOutfitID = "leaf"
    value.healthSharingScope = .limitedHealthSummary
    try await first.save(value)

    let second = PreferencesRepository(store: store)
    #expect(try await second.load() == value)
  }

  @Test("Future schemas fail closed")
  func schemaGuard() async {
    let repository = PreferencesRepository(store: InMemoryPreferencesDataStore())
    let future = AppPreferences(schemaVersion: AppPreferences.currentSchemaVersion + 1)

    await #expect(throws: PreferencesRepositoryError.unsupportedSchema(2)) {
      try await repository.save(future)
    }
  }
}
