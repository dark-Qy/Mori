import Foundation

public enum LegacyStoreKind: String, Codable, Equatable, Sendable {
  case real
  case mock
}

/// A stable storage key, not a display name. Real and Mock stores must use
/// distinct keys so resetting one can never authorize mutation of the other.
public struct LegacyStoreScope: Codable, Equatable, Hashable, Sendable {
  public let kind: LegacyStoreKind
  public let storeKey: String

  public init(kind: LegacyStoreKind, storeKey: String) throws {
    let normalized = storeKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= 128 else {
      throw LegacyResetError.invalidStoreScope
    }
    self.kind = kind
    self.storeKey = normalized
  }
}

public enum PreservedReminderMode: String, Codable, Equatable, Sendable {
  case liftWrist
  case lightHaptic
}

/// Only independently valid user choices survive the development reset.
/// Progression counters and inferred health state are intentionally absent.
public struct LegacyPreservedPreferences: Codable, Equatable, Sendable {
  public var hasCompletedOnboarding: Bool
  public var companionID: String?
  public var outfitID: String?
  public var backgroundID: String?
  public var reminderMode: PreservedReminderMode?
  public var quietHoursStartMinute: Int?
  public var quietHoursEndMinute: Int?
  public var socialSharingEnabled: Bool?
  public var healthSharingScope: String?

  public init(
    hasCompletedOnboarding: Bool = false,
    companionID: String? = nil,
    outfitID: String? = nil,
    backgroundID: String? = nil,
    reminderMode: PreservedReminderMode? = nil,
    quietHoursStartMinute: Int? = nil,
    quietHoursEndMinute: Int? = nil,
    socialSharingEnabled: Bool? = nil,
    healthSharingScope: String? = nil
  ) {
    self.hasCompletedOnboarding = hasCompletedOnboarding
    self.companionID = companionID
    self.outfitID = outfitID
    self.backgroundID = backgroundID
    self.reminderMode = reminderMode
    self.quietHoursStartMinute = quietHoursStartMinute
    self.quietHoursEndMinute = quietHoursEndMinute
    self.socialSharingEnabled = socialSharingEnabled
    self.healthSharingScope = healthSharingScope
  }
}

public struct LegacyResetMarker: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1
  public static let currentResetVersion = 1

  public let schemaVersion: Int
  public let resetVersion: Int
  public let scope: LegacyStoreScope

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    resetVersion: Int = Self.currentResetVersion,
    scope: LegacyStoreScope
  ) {
    self.schemaVersion = schemaVersion
    self.resetVersion = resetVersion
    self.scope = scope
  }
}

public enum LegacyResetBlockReason: Equatable, Sendable {
  case futureMarkerSchema(Int)
  case futureResetVersion(Int)
  case futureProgressionSchema(Int)
  case futurePreferencesSchema(Int)
  case malformedMarker
  case markerScopeMismatch
}

public enum LegacyResetPlan: Equatable, Sendable {
  case alreadyApplied(marker: LegacyResetMarker)
  case apply(
    marker: LegacyResetMarker,
    preservedPreferences: LegacyPreservedPreferences,
    deleteLegacyProgression: Bool
  )
  case blocked(LegacyResetBlockReason)
}

public enum LegacyResetError: Error, Equatable, Sendable {
  case invalidStoreScope
}

/// Plans a one-time development reset without mutating storage. The caller must
/// persist the new empty Mori ledger and marker atomically before deleting old
/// progression bytes. Future schemas fail closed and remain untouched.
public struct LegacyDevelopmentReset: Sendable {
  public static let supportedLegacyProgressionSchema = 1
  public static let supportedLegacyPreferencesSchema = 1
  public static let supportedNotificationConsentVersion = 1

  private static let allowedCompanionIDs: Set<String> = ["penguin", "polar_bear"]
  private static let allowedHealthSharingScopes: Set<String> = [
    "gameStateOnly", "careSummary", "limitedHealthSummary",
  ]

  private let codec: CanonicalJSONCodec

  public init(codec: CanonicalJSONCodec = CanonicalJSONCodec()) {
    self.codec = codec
  }

  public func plan(
    scope: LegacyStoreScope,
    progressionData: Data?,
    preferencesData: Data?,
    markerData: Data?
  ) -> LegacyResetPlan {
    if let markerData {
      let marker: LegacyResetMarker
      do {
        marker = try codec.decode(LegacyResetMarker.self, from: markerData)
      } catch {
        return .blocked(.malformedMarker)
      }
      guard marker.schemaVersion <= LegacyResetMarker.currentSchemaVersion else {
        return .blocked(.futureMarkerSchema(marker.schemaVersion))
      }
      guard marker.resetVersion <= LegacyResetMarker.currentResetVersion else {
        return .blocked(.futureResetVersion(marker.resetVersion))
      }
      guard marker.scope == scope else {
        return .blocked(.markerScopeMismatch)
      }
      if marker.resetVersion == LegacyResetMarker.currentResetVersion {
        return .alreadyApplied(marker: marker)
      }
    }

    if let version = topLevelSchemaVersion(in: progressionData),
      version > Self.supportedLegacyProgressionSchema
    {
      return .blocked(.futureProgressionSchema(version))
    }
    if let version = topLevelSchemaVersion(in: preferencesData),
      version > Self.supportedLegacyPreferencesSchema
    {
      return .blocked(.futurePreferencesSchema(version))
    }

    return .apply(
      marker: LegacyResetMarker(scope: scope),
      preservedPreferences: preservedPreferences(from: preferencesData),
      deleteLegacyProgression: progressionData != nil
    )
  }

  public func encodeMarker(_ marker: LegacyResetMarker) throws -> Data {
    try codec.encode(marker)
  }

  private func topLevelSchemaVersion(in data: Data?) -> Int? {
    guard
      let data,
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any]
    else {
      return nil
    }
    return dictionary["schemaVersion"] as? Int
  }

  private func preservedPreferences(from data: Data?) -> LegacyPreservedPreferences {
    guard
      let data,
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any],
      dictionary["schemaVersion"] as? Int == Self.supportedLegacyPreferencesSchema
    else {
      return LegacyPreservedPreferences()
    }

    let consentVersion = dictionary["proactiveNotificationConsentVersion"] as? Int
    let onboardingIsCurrent =
      (dictionary["hasCompletedOnboarding"] as? Bool) == true
      && consentVersion == Self.supportedNotificationConsentVersion

    let companionID = firstAllowedCompanionID(in: dictionary["selectedCharacterIDs"])
    let outfitID = validatedIdentifier(dictionary["selectedOutfitID"])
    let backgroundID = validatedIdentifier(dictionary["selectedBackgroundID"])
    let reminderMode = validatedReminderMode(dictionary["reminderMode"])
    let quietHours = validatedQuietHours(dictionary)
    let socialSharingEnabled = dictionary["socialSharingEnabled"] as? Bool
    let healthSharingScope = (dictionary["healthSharingScope"] as? String).flatMap {
      Self.allowedHealthSharingScopes.contains($0) ? $0 : nil
    }

    return LegacyPreservedPreferences(
      hasCompletedOnboarding: onboardingIsCurrent,
      companionID: companionID,
      outfitID: outfitID,
      backgroundID: backgroundID,
      reminderMode: reminderMode,
      quietHoursStartMinute: quietHours?.start,
      quietHoursEndMinute: quietHours?.end,
      socialSharingEnabled: socialSharingEnabled,
      healthSharingScope: healthSharingScope
    )
  }

  private func firstAllowedCompanionID(in value: Any?) -> String? {
    guard let identifiers = value as? [String] else { return nil }
    return identifiers.first(where: Self.allowedCompanionIDs.contains)
  }

  private func validatedIdentifier(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= 128 else { return nil }
    return normalized
  }

  private func validatedReminderMode(_ value: Any?) -> PreservedReminderMode? {
    guard let rawValue = value as? String else { return nil }
    return PreservedReminderMode(rawValue: rawValue)
  }

  private func validatedQuietHours(
    _ dictionary: [String: Any]
  ) -> (start: Int, end: Int)? {
    guard
      let start = dictionary["quietHoursStartMinute"] as? Int,
      let end = dictionary["quietHoursEndMinute"] as? Int,
      (0...1_439).contains(start),
      (0...1_439).contains(end)
    else {
      return nil
    }
    return (start, end)
  }
}
