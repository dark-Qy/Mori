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
    preferences: AppPreferences?
  ) -> [String: String] {
    [
      "name": companion.pet.name,
      "mood": companion.pet.mood.rawValue,
      "theme": companion.activeTheme.rawValue,
      "vitality": String(companion.growth.vitality),
      "chapter": String(companion.story.mainlineChapter),
      "outfit": preferences?.selectedOutfitID ?? companion.pet.equippedOutfitID ?? "default",
      "proactiveMessagesEnabled": String(preferences?.proactiveMessagesEnabled ?? false),
      "proactiveNotificationConsentVersion": String(
        preferences?.proactiveNotificationConsentVersion ?? 0
      ),
      "quietHoursStartMinute": String(preferences?.quietHoursStartMinute ?? 1_320),
      "quietHoursEndMinute": String(preferences?.quietHoursEndMinute ?? 420),
    ]
  }

  func makeState(
    companion: CompanionState,
    preferences: AppPreferences?,
    revision: UInt64,
    updatedAt: Date
  ) -> CompanionSyncState {
    CompanionSyncState(
      revision: revision,
      updatedAt: updatedAt,
      values: makeValues(companion: companion, preferences: preferences)
    )
  }
}
