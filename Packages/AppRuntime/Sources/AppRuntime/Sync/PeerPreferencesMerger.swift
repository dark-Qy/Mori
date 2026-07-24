import Foundation

/// Applies the management subset accepted from the paired iPhone. The touch-exchange consent
/// switch and game-only public social state are synchronized so Watch cannot bypass the owner's
/// phone setting. Health-sharing scope remains directional and is not accepted here.
struct PeerPreferencesMerger: Sendable {
  func merge(
    _ values: [String: String],
    into preferences: AppPreferences,
    acceptPhoneOwnedSocialSettings: Bool = true
  ) -> AppPreferences {
    var updated = preferences
    if let outfit = values["outfit"], WardrobeCatalog.contains(outfit) {
      updated.selectedOutfitID = outfit
    }
    if let characters = values["characters"] {
      let requested = characters.split(separator: ",").map(String.init)
      if !requested.isEmpty,
        requested.count <= CompanionVisualCatalog.maximumCharacterCount,
        requested.allSatisfy(CompanionVisualCatalog.characterIDs.contains)
      {
        updated.selectedCharacterIDs =
          CompanionVisualCatalog.normalizedCharacterIDs(requested)
      }
    }
    if let background = values["background"],
      CompanionVisualCatalog.backgroundIDs.contains(background)
    {
      updated.selectedBackgroundID = background
    }
    if let enabled = values["proactiveMessagesEnabled"].flatMap(Bool.init) {
      updated.proactiveMessagesEnabled = enabled
    }
    if let consentVersion = values["proactiveNotificationConsentVersion"].flatMap(Int.init) {
      updated.proactiveNotificationConsentVersion = consentVersion
    }
    if acceptPhoneOwnedSocialSettings {
      if let authorityVersion = values["phoneSocialSettingsAuthorityVersion"].flatMap(Int.init),
        authorityVersion >= AppPreferences.currentPhoneSocialSettingsAuthorityVersion,
        let socialSharingEnabled = values["socialSharingEnabled"].flatMap(Bool.init)
      {
        updated.phoneSocialSettingsAuthorityVersion = authorityVersion
        updated.socialSharingEnabled = socialSharingEnabled
        if let rawSocialState = values["publicPetSocialState"],
          let socialState = PublicPetSocialStateV1(rawValue: rawSocialState)
        {
          updated.publicPetSocialState = socialState
        }
      }
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
