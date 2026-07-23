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
    #expect(value.publicPetSocialState == .greeting)
    #expect(value.healthSharingScope == .careSummary)
    #expect(!value.proactiveMessagesEnabled)
    #expect(value.proactiveNotificationConsentVersion == 0)
    #expect(value.selectedCharacterIDs == ["penguin"])
    #expect(value.selectedBackgroundID == "ice_ocean_day")
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
    #expect(decoded.publicPetSocialState == .greeting)
    #expect(decoded.selectedCharacterIDs == ["penguin"])
    #expect(decoded.selectedBackgroundID == "ice_ocean_day")
  }

  @Test("Preferences persist across repository instances")
  func roundTrip() async throws {
    let store = InMemoryPreferencesDataStore()
    let first = PreferencesRepository(store: store)
    var value = try await first.load()
    value.hasCompletedOnboarding = true
    value.selectedOutfitID = "leaf"
    value.selectedCharacterIDs = ["polar_bear", "penguin"]
    value.selectedBackgroundID = "aurora_observatory"
    value.healthSharingScope = .limitedHealthSummary
    value.socialSharingEnabled = true
    value.publicPetSocialState = .quietCompany
    try await first.save(value)

    let second = PreferencesRepository(store: store)
    #expect(try await second.load() == value)
  }

  @Test("Visual selection preserves ordered duo slots and rejects unsupported IDs")
  func visualSelectionContract() {
    #expect(
      CompanionVisualCatalog.normalizedCharacterIDs([
        "polar_bear", "penguin", "polar_bear", "../../unknown",
      ]) == ["polar_bear", "penguin"]
    )
    #expect(CompanionVisualCatalog.normalizedCharacterIDs(["../../unknown"]) == ["penguin"])
    #expect(
      CompanionVisualCatalog.normalizedBackgroundID("../../unknown")
        == CompanionVisualCatalog.defaultBackgroundID
    )
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
