import AppleAdapters
import Domain
import Foundation

/// Builds the latest-value management state shared through WatchConnectivity.
///
/// Growth and health remain Watch-local. This projection intentionally contains only derived pet
/// display state and user-controlled management preferences, so retrying it is idempotent.
struct PeerStateProjection: Sendable {
  func makeValues(
    companion: CompanionState,
    preferences: AppPreferences?,
    dataSource: CompanionDataSource = .mock1,
    dataSourceSelectionToken: String? = nil,
    includePhoneOwnedSocialSettings: Bool = true
  ) -> [String: String] {
    var values = [
      "name": companion.pet.name,
      "mood": companion.pet.mood.rawValue,
      "theme": companion.activeTheme.rawValue,
      "vitality": String(companion.growth.vitality),
      "chapter": String(companion.story.mainlineChapter),
      "outfit": preferences?.selectedOutfitID ?? companion.pet.equippedOutfitID ?? "default",
      "characters": CompanionVisualCatalog.normalizedCharacterIDs(
        preferences?.selectedCharacterIDs ?? [CompanionVisualCatalog.defaultCharacterID]
      ).joined(separator: ","),
      "background": CompanionVisualCatalog.normalizedBackgroundID(
        preferences?.selectedBackgroundID ?? CompanionVisualCatalog.defaultBackgroundID
      ),
      "dataSource": dataSource.rawValue,
      "proactiveMessagesEnabled": String(preferences?.proactiveMessagesEnabled ?? false),
      "proactiveNotificationConsentVersion": String(
        preferences?.proactiveNotificationConsentVersion ?? 0
      ),
      "quietHoursStartMinute": String(preferences?.quietHoursStartMinute ?? 1_320),
      "quietHoursEndMinute": String(preferences?.quietHoursEndMinute ?? 420),
    ]
    if includePhoneOwnedSocialSettings, let preferences {
      values["phoneSocialSettingsAuthorityVersion"] = String(
        AppPreferences.currentPhoneSocialSettingsAuthorityVersion
      )
      values["socialSharingEnabled"] = String(preferences.socialSharingEnabled)
      values["publicPetSocialState"] = preferences.publicPetSocialState.rawValue
    }
    if let dataSourceSelectionToken {
      values["dataSourceSelectionToken"] = dataSourceSelectionToken
    }
    return values
  }

  func makeState(
    companion: CompanionState,
    preferences: AppPreferences?,
    dataSource: CompanionDataSource = .mock1,
    dataSourceSelectionToken: String? = nil,
    includePhoneOwnedSocialSettings: Bool = true,
    revision: UInt64,
    updatedAt: Date
  ) -> CompanionSyncState {
    CompanionSyncState(
      revision: revision,
      updatedAt: updatedAt,
      values: makeValues(
        companion: companion,
        preferences: preferences,
        dataSource: dataSource,
        dataSourceSelectionToken: dataSourceSelectionToken,
        includePhoneOwnedSocialSettings: includePhoneOwnedSocialSettings
      )
    )
  }
}
