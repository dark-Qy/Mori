import Foundation
import MoriDomain
import MoriPersistence

public typealias PreferenceRevision = LamportRevision

public enum CompanionReminderMode: String, CaseIterable, Codable, Sendable {
  /// No haptic. A fresh event is shown once on the next eligible activation.
  case wristRaise

  /// The same foreground glance may emit one best-effort gentle haptic.
  case gentleHaptic
}

public struct CompanionQuietHours: Hashable, Codable, Sendable {
  public let startMinute: Int
  public let endMinute: Int

  public init(startMinute: Int, endMinute: Int) {
    self.startMinute = startMinute
    self.endMinute = endMinute
  }

  public var isValid: Bool {
    (0...1_439).contains(startMinute)
      && (0...1_439).contains(endMinute)
      && startMinute != endMinute
  }

  public func contains(minuteOfDay: Int) -> Bool {
    guard isValid, (0...1_439).contains(minuteOfDay) else { return false }
    if startMinute < endMinute {
      return minuteOfDay >= startMinute && minuteOfDay < endMinute
    }
    return minuteOfDay >= startMinute || minuteOfDay < endMinute
  }
}

public struct CompanionSensingPreference: Hashable, Codable, Sendable {
  public let enabled: Bool
  public let epoch: SensingEpoch

  public init(enabled: Bool, epoch: SensingEpoch) {
    self.enabled = enabled
    self.epoch = epoch
  }
}

public struct RevisionedPreference<Value>: Hashable, Codable, Sendable
where Value: Hashable & Codable & Sendable {
  public let value: Value
  public let revision: PreferenceRevision

  public init(value: Value, revision: PreferenceRevision) {
    self.value = value
    self.revision = revision
  }
}

public struct GlobalSyncedPreferences: Hashable, Codable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let profileSelection: ProfileSelectionRecord
  public let companionSensing: RevisionedPreference<CompanionSensingPreference>
  public let reminderMode: RevisionedPreference<CompanionReminderMode>
  public let quietHours: RevisionedPreference<CompanionQuietHours>

  public init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    profileSelection: ProfileSelectionRecord,
    companionSensing: RevisionedPreference<CompanionSensingPreference>,
    reminderMode: RevisionedPreference<CompanionReminderMode>,
    quietHours: RevisionedPreference<CompanionQuietHours>
  ) {
    self.schemaVersion = schemaVersion
    self.profileSelection = profileSelection
    self.companionSensing = companionSensing
    self.reminderMode = reminderMode
    self.quietHours = quietHours
  }

  public var isValid: Bool {
    schemaVersion == Self.currentSchemaVersion
      && profileSelection.isValid
      && companionSensing.revision.isValid
      && companionSensing.value.epoch.isValid
      && companionSensing.value.epoch.revision == companionSensing.revision
      && reminderMode.revision.isValid
      && quietHours.revision.isValid
      && quietHours.value.isValid
  }

  public var maximumCounter: UInt64 {
    max(
      profileSelection.revision.counter,
      companionSensing.revision.counter,
      reminderMode.revision.counter,
      quietHours.revision.counter
    )
  }
}

public enum GlobalPreferenceMergeRejection: Error, Equatable, Sendable {
  case invalidCurrent
  case invalidIncoming
  case conflictingProfileSelection
  case conflictingCompanionSensing
  case conflictingReminderMode
  case conflictingQuietHours
}

public enum GlobalPreferenceMergeResult: Equatable, Sendable {
  case applied(GlobalSyncedPreferences)
  case duplicate(GlobalSyncedPreferences)
  case rejected(GlobalPreferenceMergeRejection)
}

/// Merges each independent preference register by complete Lamport order.
/// Wall-clock time and delivery order never participate.
public enum GlobalPreferenceMerger {
  public static func merge(
    current: GlobalSyncedPreferences,
    incoming: GlobalSyncedPreferences
  ) -> GlobalPreferenceMergeResult {
    guard current.isValid else { return .rejected(.invalidCurrent) }
    guard incoming.isValid else { return .rejected(.invalidIncoming) }

    let profileSelection = select(
      current: current.profileSelection,
      currentRevision: current.profileSelection.revision,
      incoming: incoming.profileSelection,
      incomingRevision: incoming.profileSelection.revision
    )

    let companionSensing = selectCompanionSensing(
      current: current.companionSensing,
      incoming: incoming.companionSensing
    )

    let reminderMode = select(
      current: current.reminderMode,
      currentRevision: current.reminderMode.revision,
      incoming: incoming.reminderMode,
      incomingRevision: incoming.reminderMode.revision
    )

    let quietHours = select(
      current: current.quietHours,
      currentRevision: current.quietHours.revision,
      incoming: incoming.quietHours,
      incomingRevision: incoming.quietHours.revision
    )

    let merged = GlobalSyncedPreferences(
      profileSelection: profileSelection,
      companionSensing: companionSensing,
      reminderMode: reminderMode,
      quietHours: quietHours
    )
    guard merged.isValid else { return .rejected(.invalidIncoming) }
    return merged == current ? .duplicate(current) : .applied(merged)
  }

  /// Exact-revision corruption is resolved within one register so it cannot
  /// block a causally newer value in another independent register. Canonical
  /// minimum is commutative, associative, and idempotent, so every peer
  /// converges even when the conflicting snapshots arrive in a different
  /// order.
  private static func select<Value: Equatable & Encodable>(
    current: Value,
    currentRevision: PreferenceRevision,
    incoming: Value,
    incomingRevision: PreferenceRevision
  ) -> Value {
    if incomingRevision == currentRevision {
      guard incoming != current else { return current }
      return canonicalMinimum(current, incoming)
    }
    return incomingRevision > currentRevision
      ? incoming
      : current
  }

  /// Sensing is authorization, so an exact logical-identity conflict is not
  /// resolved arbitrarily. It converges to a synthetic disabled value carrying
  /// that same revision/epoch. A newer disabling revision still wins normally.
  private static func selectCompanionSensing(
    current: RevisionedPreference<CompanionSensingPreference>,
    incoming: RevisionedPreference<CompanionSensingPreference>
  ) -> RevisionedPreference<CompanionSensingPreference> {
    if incoming.revision == current.revision {
      guard incoming == current else {
        return RevisionedPreference(
          value: CompanionSensingPreference(
            enabled: false,
            epoch: SensingEpoch(current.revision)
          ),
          revision: current.revision
        )
      }
      return current
    }
    return incoming.revision > current.revision ? incoming : current
  }

  private static func canonicalMinimum<Value: Encodable>(
    _ first: Value,
    _ second: Value
  ) -> Value {
    let codec = CanonicalJSONCodec()
    guard
      let firstBytes = try? codec.encode(first),
      let secondBytes = try? codec.encode(second)
    else {
      // These closed preference values contain no custom throwing encoders.
      // If that invariant changes, preserving current state fails closed.
      return first
    }
    return secondBytes.lexicographicallyPrecedes(firstBytes) ? second : first
  }
}
