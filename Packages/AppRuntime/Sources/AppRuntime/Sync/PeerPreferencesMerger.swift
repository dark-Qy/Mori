import Foundation

/// Applies the management subset accepted from the paired iPhone. Health-sharing and social
/// privacy settings are intentionally not accepted through this latest-value channel.
struct PeerPreferencesMerger: Sendable {
  func merge(_ values: [String: String], into preferences: AppPreferences) -> AppPreferences {
    var updated = preferences
    if let outfit = values["outfit"], WardrobeCatalog.contains(outfit) {
      updated.selectedOutfitID = outfit
    }
    if let enabled = values["proactiveMessagesEnabled"].flatMap(Bool.init) {
      updated.proactiveMessagesEnabled = enabled
    }
    if let consentVersion = values["proactiveNotificationConsentVersion"].flatMap(Int.init) {
      updated.proactiveNotificationConsentVersion = consentVersion
    }
    if let quietStart = values["quietHoursStartMinute"].flatMap(Int.init) {
      updated.quietHoursStartMinute = max(0, min(1_439, quietStart))
    }
    if let quietEnd = values["quietHoursEndMinute"].flatMap(Int.init) {
      updated.quietHoursEndMinute = max(0, min(1_439, quietEnd))
    }
    return updated
  }
}
