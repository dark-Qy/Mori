import Domain
import Foundation
import Testing

@testable import AppRuntime

@Suite("Peer management-state projection")
struct PeerStateProjectionTests {
  @Test("Wardrobe and consent settings project without raw health data")
  func projectsManagementValuesOnly() {
    let date = Date(timeIntervalSince1970: 1_760_000_000)
    let preferences = AppPreferences(
      hasCompletedOnboarding: true,
      proactiveMessagesEnabled: true,
      socialSharingEnabled: true,
      publicPetSocialState: .walk,
      healthSharingScope: .limitedHealthSummary,
      selectedOutfitID: "soccer_scarf",
      selectedCharacterIDs: ["polar_bear", "penguin"],
      selectedBackgroundID: "aurora_observatory",
      quietHoursStartMinute: 1_260,
      quietHoursEndMinute: 480
    )

    let state = PeerStateProjection().makeState(
      companion: CompanionState(),
      preferences: preferences,
      dataSource: .healthKit,
      dataSourceSelectionToken: "selection-2",
      revision: 42,
      updatedAt: date
    )

    #expect(state.revision == 42)
    #expect(state.updatedAt == date)
    #expect(state.values["outfit"] == "soccer_scarf")
    #expect(state.values["characters"] == "polar_bear,penguin")
    #expect(state.values["background"] == "aurora_observatory")
    #expect(state.values["dataSource"] == "healthKit")
    #expect(state.values["dataSourceSelectionToken"] == "selection-2")
    #expect(state.values["proactiveMessagesEnabled"] == "true")
    #expect(state.values["proactiveNotificationConsentVersion"] == "1")
    #expect(state.values["socialSharingEnabled"] == "true")
    #expect(state.values["publicPetSocialState"] == "walk")
    #expect(state.values["quietHoursStartMinute"] == "1260")
    #expect(state.values["quietHoursEndMinute"] == "480")
    #expect(state.values["healthSharingScope"] == nil)
    #expect(state.values.keys.allSatisfy { !$0.localizedCaseInsensitiveContains("health") })
  }

  @Test("Watch projection omits phone-owned social consent")
  func watchOmitsPhoneOwnedSocialSettings() {
    let values = PeerStateProjection().makeValues(
      companion: CompanionState(),
      preferences: AppPreferences(
        socialSharingEnabled: true,
        publicPetSocialState: .walk
      ),
      includePhoneOwnedSocialSettings: false
    )

    #expect(values["socialSharingEnabled"] == nil)
    #expect(values["publicPetSocialState"] == nil)
  }

  @Test("Default outfit is deterministic when neither side selected one")
  func fallsBackToDefaultOutfit() {
    let state = PeerStateProjection().makeState(
      companion: CompanionState(),
      preferences: nil,
      revision: 1,
      updatedAt: .distantPast
    )

    #expect(state.values["outfit"] == "default")
    #expect(state.values["characters"] == "penguin")
    #expect(state.values["background"] == "spring_meadow_stream")
    #expect(state.values["socialSharingEnabled"] == "false")
    #expect(state.values["publicPetSocialState"] == "greeting")
  }
}
