import AppRuntime
import Foundation
import Testing

@Suite("Application preferences")
struct PreferencesRuntimeTests {
  @Test("Pet-card sharing starts enabled while sensitive capabilities remain gated")
  func privacyDefaults() {
    let value = AppPreferences()

    #expect(!value.hasCompletedOnboarding)
    #expect(value.socialSharingEnabled)
    #expect(value.phoneSocialSettingsAuthorityVersion == nil)
    #expect(value.publicPetSocialState == .greeting)
    #expect(value.healthSharingScope == .careSummary)
    #expect(!value.proactiveMessagesEnabled)
    #expect(value.proactiveNotificationConsentVersion == 0)
    #expect(value.selectedCharacterIDs == ["penguin"])
    #expect(value.selectedBackgroundID == "spring_meadow_stream")
  }

  @Test("Legacy preferences without a social setting adopt the new default")
  func legacyMissingSocialSettingUsesDefault() throws {
    let legacy = Data(
      """
      {
        "schemaVersion": 1,
        "proactiveMessagesEnabled": false,
        "healthSharingScope": "careSummary",
        "selectedOutfitID": "default",
        "quietHoursStartMinute": 1320,
        "quietHoursEndMinute": 420
      }
      """.utf8
    )

    let decoded = try JSONDecoder().decode(AppPreferences.self, from: legacy)
    #expect(decoded.socialSharingEnabled)
    #expect(decoded.phoneSocialSettingsAuthorityVersion == nil)
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
    #expect(!decoded.socialSharingEnabled)
    #expect(decoded.phoneSocialSettingsAuthorityVersion == nil)
    #expect(decoded.publicPetSocialState == .greeting)
    #expect(decoded.selectedCharacterIDs == ["penguin"])
    #expect(decoded.selectedBackgroundID == "spring_meadow_stream")
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
    #expect(
      CompanionVisualCatalog.normalizedCharacterIDs([
        "bili_22", "bili_33", "penguin",
      ]) == ["bili_22", "bili_33"]
    )
    #expect(CompanionVisualCatalog.characterDisplayName("bili_22") == "22 娘")
    #expect(CompanionVisualCatalog.characterDisplayName("bili_33") == "33 娘")
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
