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
      healthSharingScope: .limitedHealthSummary,
      selectedOutfitID: "soccer_scarf",
      quietHoursStartMinute: 1_260,
      quietHoursEndMinute: 480
    )

    let state = PeerStateProjection().makeState(
      companion: CompanionState(),
      preferences: preferences,
      dataSource: .mock2,
      dataSourceSelectionToken: "selection-2",
      revision: 42,
      updatedAt: date
    )

    #expect(state.revision == 42)
    #expect(state.updatedAt == date)
    #expect(state.values["outfit"] == "soccer_scarf")
    #expect(state.values["dataSource"] == "mock2")
    #expect(state.values["dataSourceSelectionToken"] == "selection-2")
    #expect(state.values["proactiveMessagesEnabled"] == "true")
    #expect(state.values["proactiveNotificationConsentVersion"] == "1")
    #expect(state.values["quietHoursStartMinute"] == "1260")
    #expect(state.values["quietHoursEndMinute"] == "480")
    #expect(state.values["healthSharingScope"] == nil)
    #expect(state.values["socialSharingEnabled"] == nil)
    #expect(state.values.keys.allSatisfy { !$0.localizedCaseInsensitiveContains("health") })
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
  }
}
