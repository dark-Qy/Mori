import Testing

@testable import AppRuntime

@Suite("Paired management preference merge")
struct PeerPreferencesMergerTests {
  @Test("Supported outfit and bounded notification settings are accepted")
  func appliesSupportedValues() {
    let merged = PeerPreferencesMerger().merge(
      [
        "outfit": "soccer_scarf",
        "characters": "polar_bear,penguin",
        "background": "aurora_observatory",
        "proactiveMessagesEnabled": "true",
        "proactiveNotificationConsentVersion": "1",
        "socialSharingEnabled": "true",
        "publicPetSocialState": "walk",
        "quietHoursStartMinute": "2000",
        "quietHoursEndMinute": "-4",
      ],
      into: AppPreferences(hasCompletedOnboarding: true)
    )

    #expect(merged.selectedOutfitID == "soccer_scarf")
    #expect(merged.selectedCharacterIDs == ["polar_bear", "penguin"])
    #expect(merged.selectedBackgroundID == "aurora_observatory")
    #expect(merged.proactiveMessagesEnabled)
    #expect(merged.proactiveNotificationConsentVersion == 1)
    #expect(merged.socialSharingEnabled)
    #expect(merged.publicPetSocialState == .walk)
    #expect(merged.quietHoursStartMinute == 1_439)
    #expect(merged.quietHoursEndMinute == 0)
  }

  @Test("Phone-owned social settings cannot be overwritten by the Watch")
  func phoneIgnoresWatchSocialValues() {
    let original = AppPreferences(
      socialSharingEnabled: false,
      publicPetSocialState: .quietCompany
    )
    let merged = PeerPreferencesMerger().merge(
      [
        "socialSharingEnabled": "true",
        "publicPetSocialState": "walk",
        "outfit": "leaf",
      ],
      into: original,
      acceptPhoneOwnedSocialSettings: false
    )

    #expect(!merged.socialSharingEnabled)
    #expect(merged.publicPetSocialState == .quietCompany)
    #expect(merged.selectedOutfitID == "leaf")
  }

  @Test("Unknown outfit and privacy values fail closed")
  func ignoresUnsupportedValues() {
    let original = AppPreferences(
      hasCompletedOnboarding: true,
      socialSharingEnabled: false,
      healthSharingScope: .careSummary,
      selectedOutfitID: "default",
      selectedCharacterIDs: ["polar_bear"],
      selectedBackgroundID: "summer_lake"
    )
    let merged = PeerPreferencesMerger().merge(
      [
        "outfit": "../../unknown",
        "characters": "../../unknown",
        "background": "../../unknown",
        "socialSharingEnabled": "not-a-bool",
        "publicPetSocialState": "raw_health_signal",
        "healthSharingScope": "limitedHealthSummary",
      ],
      into: original
    )

    #expect(merged == original)
  }

  @Test("A partial legacy payload preserves the current character and background")
  func preservesVisualPreferencesWhenPeerOmitsThem() {
    let original = AppPreferences(
      selectedOutfitID: "default",
      selectedCharacterIDs: ["polar_bear"],
      selectedBackgroundID: "summer_lake"
    )

    let merged = PeerPreferencesMerger().merge(
      ["proactiveMessagesEnabled": "true"],
      into: original
    )

    #expect(merged.selectedCharacterIDs == ["polar_bear"])
    #expect(merged.selectedBackgroundID == "summer_lake")
  }
}
