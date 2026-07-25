import Foundation
import MoriDomain

public enum MoriGlobalPreferenceRuntimeError: Error, Equatable, Sendable {
  case invalidOriginDeviceID
  case invalidMockScenarioID
  case invalidQuietHours
  case rejectedPreference
  case staleDeletionScope
  case staleSensingScope
  case consentExpansionRequiresPhone
  case invalidDisclosureVersion
}

public enum MoriGlobalProfileSource: Equatable, Sendable {
  case real
  case mock(scenarioID: String)
}

/// App-safe identity for one selected profile generation.
///
/// The scenario name alone is never a storage boundary. A fresh Mock
/// selection receives a new profile epoch and therefore a new `storageKey`.
/// App mutations capture this complete value and compare it again after every
/// suspension point before publishing a result.
public struct MoriGlobalProfileScope: Hashable, Sendable {
  public let profileID: String
  public let profileEpochCounter: UInt64
  public let profileEpochOriginDeviceID: String
  public let deletionRequestID: String
  public let deletionEpochCounter: UInt64
  public let deletionEpochOriginDeviceID: String
  public let mockScenarioID: String?
  public let storageKey: String

  public var isMock: Bool { mockScenarioID != nil }

  init(profile: RuntimeProfile) {
    profileID = profile.id.rawValue
    profileEpochCounter = profile.epoch.revision.counter
    profileEpochOriginDeviceID = profile.epoch.revision.originDeviceID
    deletionRequestID = profile.deletionEpoch.requestID.rawValue
    deletionEpochCounter = profile.deletionEpoch.revision.counter
    deletionEpochOriginDeviceID =
      profile.deletionEpoch.revision.originDeviceID
    if case .mock(let scenarioID, _) = profile.source {
      mockScenarioID = scenarioID.rawValue
    } else {
      mockScenarioID = nil
    }
    storageKey = RuntimeStorageLayout.namespaceID(for: profile)
  }
}

public struct MoriGlobalSensingScope: Hashable, Sendable {
  public let enabled: Bool
  public let epochCounter: UInt64
  public let epochOriginDeviceID: String

  init(preference: CompanionSensingPreference) {
    enabled = preference.enabled
    epochCounter = preference.epoch.revision.counter
    epochOriginDeviceID = preference.epoch.revision.originDeviceID
  }
}

public struct MoriGlobalPreferenceProjection: Equatable, Sendable {
  public let profileSource: MoriGlobalProfileSource
  public let profileScope: MoriGlobalProfileScope
  public let sensingScope: MoriGlobalSensingScope
  public let companionSensingEnabled: Bool
  public let reminderMode: CompanionReminderMode
  public let quietHours: CompanionQuietHours
}

/// Small app-facing façade over the durable GSP/GCS authority.
///
/// Both Apple clients use the same file format and mutation rules. Transport
/// synchronization remains a separate concern; a local choice is durable even
/// while the peer is unavailable.
public actor MoriGlobalPreferenceRuntime {
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
        revision: revision,
        currentProfile: current.profileSelection.profile
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

  public func currentChatAuthority() async throws -> ChatAuthoritySnapshot {
    let current = try await repository.current()
    return ChatAuthoritySnapshot(
      profile: current.preferences.profileSelection.profile,
      remoteChatConsent: current.consent.remoteChat,
      memoryContextConsent: current.consent.memoryContext
    )
  }

  @discardableResult
  public func setConsent(
    _ kind: MoriConsentKind,
    enabled: Bool,
    disclosureVersion: UInt16? = nil
  ) async throws -> ChatAuthoritySnapshot {
    let author: ConsentAuthorDevice =
      originDeviceID == "phone" ? .phone : .watch
    if enabled, author != .phone {
      throw MoriGlobalPreferenceRuntimeError.consentExpansionRequiresPhone
    }
    let version =
      enabled
      ? disclosureVersion ?? kind.requiredDisclosureVersion
      : 0
    guard !enabled || version >= kind.requiredDisclosureVersion else {
      throw MoriGlobalPreferenceRuntimeError.invalidDisclosureVersion
    }

    let current = try await repository.current()
    let maximumConsentCounter =
      MoriConsentKind.allCases
      .map { current.consent[$0].revision.counter }
      .max() ?? 0
    let revision = LamportRevision(
      counter: max(
        current.preferences.maximumCounter,
        maximumConsentCounter
      ) &+ 1,
      originDeviceID: originDeviceID
    )
    let record = MoriConsentRecord(
      enabled: enabled,
      disclosureVersion: version,
      revision: revision,
      authorDevice: author
    )
    let candidate = current.consent.replacing(kind, with: record)
    let result = try await repository.merge(
      consent: candidate,
      deletionRoot: current.deletionRoot
    )
    let consent: GlobalConsentState
    switch result {
    case .applied(let value), .duplicate(let value):
      consent = value
    case .rejected:
      throw MoriGlobalPreferenceRuntimeError.rejectedPreference
    }
    let latest = try await repository.current().preferences
    return ChatAuthoritySnapshot(
      profile: latest.profileSelection.profile,
      remoteChatConsent: consent.remoteChat,
      memoryContextConsent: consent.memoryContext
    )
  }

  /// Executes one synchronous mutation while the captured profile and sensing
  /// scopes are still authoritative. Because the mutation does not suspend,
  /// a sensing revocation on this façade cannot interleave between validation
  /// and the governed ledger write.
  public func performAuthorizedSensingMutation<Result: Sendable>(
    profileScope: MoriGlobalProfileScope,
    sensingScope: MoriGlobalSensingScope,
    _ mutation: @Sendable () throws -> Result
  ) async throws -> Result {
    let current = projection(from: try await repository.current().preferences)
    guard
      current.profileScope == profileScope,
      current.sensingScope == sensingScope,
      current.companionSensingEnabled
    else {
      throw MoriGlobalPreferenceRuntimeError.staleSensingScope
    }
    return try mutation()
  }

  /// Installs a content-free, sensing-disabled authority fence before
  /// app-owned profile stores are cleared. The caller must revalidate the
  /// complete profile generation captured by the confirmation UI.
  @discardableResult
  public func deleteAllData(
    expectedProfileScope: MoriGlobalProfileScope,
    requestID: String
  ) async throws -> MoriGlobalPreferenceProjection {
    let normalizedRequestID = requestID.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let deletionRequestID = DeletionRequestID(normalizedRequestID)
    guard
      deletionRequestID.isValid,
      !deletionRequestID.isReservedBootstrapNamespace
    else {
      throw MoriGlobalPreferenceRuntimeError.rejectedPreference
    }

    let current = try await repository.current()
    let currentProfile = current.preferences.profileSelection.profile
    if currentProfile.deletionEpoch.requestID == deletionRequestID {
      return projection(from: current.preferences)
    }
    guard
      MoriGlobalProfileScope(profile: currentProfile) == expectedProfileScope
    else {
      throw MoriGlobalPreferenceRuntimeError.staleDeletionScope
    }

    let consentCounter =
      MoriConsentKind.allCases
      .map { current.consent[$0].revision.counter }
      .max() ?? 0
    let revision = LamportRevision(
      counter: max(
        current.preferences.maximumCounter,
        consentCounter
      ) &+ 1,
      originDeviceID: originDeviceID
    )
    let postDeletionProfile = RuntimeProfile(
      id: ProfileID("real"),
      epoch: ProfileEpoch(revision),
      deletionEpoch: DeletionEpoch(
        requestID: deletionRequestID,
        revision: revision
      ),
      source: .real
    )
    let preferences = GlobalSyncedPreferences(
      profileSelection: try ProfileSelectionRecord.real(
        profile: postDeletionProfile,
        selectionRevision: revision
      ),
      companionSensing: RevisionedPreference(
        value: CompanionSensingPreference(
          enabled: false,
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
    let replacement = GlobalAuthoritySnapshot(
      preferences: preferences,
      consent: .disabled(
        revision: revision,
        authorDevice: .phone
      )
    )
    try await repository.replaceForDeletion(with: replacement)
    return projection(from: preferences)
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
    let profile = preferences.profileSelection.profile
    return MoriGlobalPreferenceProjection(
      profileSource: profileSource(
        from: profile.source
      ),
      profileScope: MoriGlobalProfileScope(profile: profile),
      sensingScope: MoriGlobalSensingScope(
        preference: preferences.companionSensing.value
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
    let revision = DeletionEpoch.bootstrap.revision
    let preferences = GlobalSyncedPreferences(
      profileSelection: try profileSelection(
        for: profileSource,
        revision: revision,
        currentProfile: nil
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
    revision: LamportRevision,
    currentProfile: RuntimeProfile?
  ) throws -> ProfileSelectionRecord {
    let deletionEpoch = rootDeletionEpoch(from: currentProfile)
    switch source {
    case .real:
      if let currentProfile, currentProfile.source == .real {
        return try ProfileSelectionRecord.real(
          profile: currentProfile,
          selectionRevision: revision
        )
      }
      let profile = RuntimeProfile(
        id: ProfileID("real"),
        epoch: ProfileEpoch(deletionEpoch.revision),
        deletionEpoch: deletionEpoch,
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
      let selection = try MockProfileDerivation.selection(
        scenarioID: scenarioID,
        revision: revision
      )
      guard currentProfile != nil else { return selection }
      let derived = selection.profile
      return ProfileSelectionRecord(
        profile: RuntimeProfile(
          id: derived.id,
          epoch: derived.epoch,
          deletionEpoch: deletionEpoch,
          source: derived.source
        ),
        revision: revision
      )
    }
  }

  private static func rootDeletionEpoch(
    from currentProfile: RuntimeProfile?
  ) -> DeletionEpoch {
    guard let currentProfile else { return .bootstrap }
    switch currentProfile.deletionAuthorityRoot {
    case .bootstrap:
      return .bootstrap
    case .deletion(let epoch):
      return epoch
    }
  }
}

extension MoriGlobalPreferenceRuntime: ChatAuthorityProviding {}
