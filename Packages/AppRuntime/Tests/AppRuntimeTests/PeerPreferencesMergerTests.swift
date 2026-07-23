import Testing

@testable import AppRuntime

@Suite("Paired management preference merge")
struct PeerPreferencesMergerTests {
  @Test("Supported outfit and bounded notification settings are accepted")
  func appliesSupportedValues() {
    let merged = PeerPreferencesMerger().merge(
      [
        "outfit": "soccer_scarf",
        "proactiveMessagesEnabled": "true",
        "proactiveNotificationConsentVersion": "1",
        "quietHoursStartMinute": "2000",
        "quietHoursEndMinute": "-4",
      ],
      into: AppPreferences(hasCompletedOnboarding: true)
    )

    #expect(merged.selectedOutfitID == "soccer_scarf")
    #expect(merged.proactiveMessagesEnabled)
    #expect(merged.proactiveNotificationConsentVersion == 1)
    #expect(merged.quietHoursStartMinute == 1_439)
    #expect(merged.quietHoursEndMinute == 0)
  }

  @Test("Unknown outfit and privacy values fail closed")
  func ignoresUnsupportedValues() {
    let original = AppPreferences(
      hasCompletedOnboarding: true,
      socialSharingEnabled: false,
      healthSharingScope: .careSummary,
      selectedOutfitID: "default"
    )
    let merged = PeerPreferencesMerger().merge(
      [
        "outfit": "../../unknown",
        "socialSharingEnabled": "true",
        "healthSharingScope": "limitedHealthSummary",
      ],
      into: original
    )

    #expect(merged == original)
  }
}
