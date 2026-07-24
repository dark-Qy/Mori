import Foundation
import MoriDomain

public enum MoriGlobalPreferenceRuntimeError: Error, Equatable, Sendable {
  case invalidOriginDeviceID
  case invalidMockScenarioID
  case invalidQuietHours
  case rejectedPreference
}

public enum MoriGlobalProfileSource: Equatable, Sendable {
  case real
  case mock(scenarioID: String)
}

public struct MoriGlobalPreferenceProjection: Equatable, Sendable {
  public let profileSource: MoriGlobalProfileSource
  public let companionSensingEnabled: Bool
  public let reminderMode: CompanionReminderMode
  public let quietHours: CompanionQuietHours

  public init(
    profileSource: MoriGlobalProfileSource,
    companionSensingEnabled: Bool,
    reminderMode: CompanionReminderMode,
    quietHours: CompanionQuietHours
  ) {
    self.profileSource = profileSource
    self.companionSensingEnabled = companionSensingEnabled
    self.reminderMode = reminderMode
    self.quietHours = quietHours
  }
}

/// Small app-facing façade over the durable GSP/GCS authority.
///
/// Both Apple clients use the same file format and mutation rules. Transport
/// synchronization remains a separate concern; a local choice is durable even
/// while the peer is unavailable.
public actor MoriGlobalPreferenceRuntime {
  private static let bootstrapRevision = LamportRevision(
    counter: 1,
    originDeviceID: "mori-bootstrap"
  )

  private let originDeviceID: String
  private let repository: GlobalAuthorityRepository<FileGlobalAuthorityStorage>

  public init(
    storageURL: URL,
    originDeviceID: String,
    initialProfileSource: MoriGlobalProfileSource = .real
  ) throws {
    let normalizedOrigin = originDeviceID.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard normalizedOrigin.isEmpty == false else {
      throw MoriGlobalPreferenceRuntimeError.invalidOriginDeviceID
    }
    self.originDeviceID = normalizedOrigin
    repository = try GlobalAuthorityRepository(
      storage: FileGlobalAuthorityStorage(fileURL: storageURL),
      initialSnapshot: try Self.makeInitialSnapshot(
        profileSource: initialProfileSource
      )
    )
  }

  @discardableResult
  public func selectProfile(
    _ source: MoriGlobalProfileSource
  ) async throws -> MoriGlobalPreferenceProjection {
    try await update { current, revision in
      let selection = try Self.profileSelection(
        for: source,
        revision: revision
      )
      return GlobalSyncedPreferences(
        profileSelection: selection,
        companionSensing: current.companionSensing,
        reminderMode: current.reminderMode,
        quietHours: current.quietHours
      )
    }
  }

  public func current() async throws -> MoriGlobalPreferenceProjection {
    projection(from: try await repository.current().preferences)
  }

  @discardableResult
  public func setCompanionSensing(
    enabled: Bool
  ) async throws -> MoriGlobalPreferenceProjection {
    try await update { current, revision in
      GlobalSyncedPreferences(
        profileSelection: current.profileSelection,
        companionSensing: RevisionedPreference(
          value: CompanionSensingPreference(
            enabled: enabled,
            epoch: SensingEpoch(revision)
          ),
          revision: revision
        ),
        reminderMode: current.reminderMode,
        quietHours: current.quietHours
      )
    }
  }

  @discardableResult
  public func setReminderMode(
    _ mode: CompanionReminderMode
  ) async throws -> MoriGlobalPreferenceProjection {
    try await update { current, revision in
      GlobalSyncedPreferences(
        profileSelection: current.profileSelection,
        companionSensing: current.companionSensing,
        reminderMode: RevisionedPreference(
          value: mode,
          revision: revision
        ),
        quietHours: current.quietHours
      )
    }
  }

  @discardableResult
  public func setQuietHours(
    _ quietHours: CompanionQuietHours
  ) async throws -> MoriGlobalPreferenceProjection {
    guard quietHours.isValid else {
      throw MoriGlobalPreferenceRuntimeError.invalidQuietHours
    }
    return try await update { current, revision in
      GlobalSyncedPreferences(
        profileSelection: current.profileSelection,
        companionSensing: current.companionSensing,
        reminderMode: current.reminderMode,
        quietHours: RevisionedPreference(
          value: quietHours,
          revision: revision
        )
      )
    }
  }

  private func update(
    _ replacement: (
      GlobalSyncedPreferences,
      LamportRevision
    ) throws -> GlobalSyncedPreferences
  ) async throws -> MoriGlobalPreferenceProjection {
    let current = try await repository.current().preferences
    let revision = LamportRevision(
      counter: current.maximumCounter &+ 1,
      originDeviceID: originDeviceID
    )
    let candidate = try replacement(current, revision)
    let result = try await repository.merge(preferences: candidate)
    switch result {
    case .applied(let value), .duplicate(let value):
      return projection(from: value)
    case .rejected:
      throw MoriGlobalPreferenceRuntimeError.rejectedPreference
    }
  }

  private func projection(
    from preferences: GlobalSyncedPreferences
  ) -> MoriGlobalPreferenceProjection {
    MoriGlobalPreferenceProjection(
      profileSource: profileSource(
        from: preferences.profileSelection.profile.source
      ),
      companionSensingEnabled: preferences.companionSensing.value.enabled,
      reminderMode: preferences.reminderMode.value,
      quietHours: preferences.quietHours.value
    )
  }

  private func profileSource(
    from source: RuntimeProfileSource
  ) -> MoriGlobalProfileSource {
    switch source {
    case .real:
      .real
    case .mock(let scenarioID, _):
      .mock(scenarioID: scenarioID.rawValue)
    }
  }

  private static func makeInitialSnapshot(
    profileSource: MoriGlobalProfileSource
  ) throws -> GlobalAuthoritySnapshot {
    let revision = bootstrapRevision
    let preferences = GlobalSyncedPreferences(
      profileSelection: try profileSelection(
        for: profileSource,
        revision: revision
      ),
      companionSensing: RevisionedPreference(
        value: CompanionSensingPreference(
          enabled: true,
          epoch: SensingEpoch(revision)
        ),
        revision: revision
      ),
      reminderMode: RevisionedPreference(
        value: .wristRaise,
        revision: revision
      ),
      quietHours: RevisionedPreference(
        value: CompanionQuietHours(
          startMinute: 22 * 60,
          endMinute: 7 * 60
        ),
        revision: revision
      )
    )
    return GlobalAuthoritySnapshot(
      preferences: preferences,
      consent: .disabled(
        revision: revision,
        authorDevice: .phone
      )
    )
  }

  private static func profileSelection(
    for source: MoriGlobalProfileSource,
    revision: LamportRevision
  ) throws -> ProfileSelectionRecord {
    switch source {
    case .real:
      let profile = RuntimeProfile(
        id: ProfileID("real"),
        epoch: ProfileEpoch(bootstrapRevision),
        deletionEpoch: DeletionEpoch(
          requestID: DeletionRequestID("baseline"),
          revision: bootstrapRevision
        ),
        source: .real
      )
      return try ProfileSelectionRecord.real(
        profile: profile,
        selectionRevision: revision
      )
    case .mock(let value):
      let scenarioID = MockScenarioID(value)
      guard scenarioID.isValid else {
        throw MoriGlobalPreferenceRuntimeError.invalidMockScenarioID
      }
      return try MockProfileDerivation.selection(
        scenarioID: scenarioID,
        revision: revision
      )
    }
  }
}
