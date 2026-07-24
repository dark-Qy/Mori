import CryptoKit
import Foundation
import MoriDomain

public enum ProfileSelectionError: Error, Equatable, Sendable {
  case invalidScenario
  case invalidRevision
  case invalidProfile
}

public struct ProfileSelectionRecord: Hashable, Codable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let profile: RuntimeProfile
  public let revision: LamportRevision

  public init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    profile: RuntimeProfile,
    revision: LamportRevision
  ) {
    self.schemaVersion = schemaVersion
    self.profile = profile
    self.revision = revision
  }

  public var isValid: Bool {
    guard
      schemaVersion == Self.currentSchemaVersion,
      profile.isValid,
      revision.isValid
    else {
      return false
    }
    if case .mock(_, let selectionEpoch) = profile.source {
      return selectionEpoch.revision == revision
        && profile.epoch.revision == revision
    }
    return true
  }

  public static func real(
    profile: RuntimeProfile,
    selectionRevision: LamportRevision
  ) throws -> Self {
    guard profile.isValid, profile.source == .real else {
      throw ProfileSelectionError.invalidProfile
    }
    guard selectionRevision.isValid else {
      throw ProfileSelectionError.invalidRevision
    }
    return Self(profile: profile, revision: selectionRevision)
  }
}

/// Deterministically derives a fresh Mock profile from a scenario and selection
/// Lamport revision. The same inputs converge across devices; selecting again
/// with a later revision creates a new epoch and a separate namespace.
public enum MockProfileDerivation {
  public static func selection(
    scenarioID: MockScenarioID,
    revision: LamportRevision
  ) throws -> ProfileSelectionRecord {
    guard scenarioID.isValid else { throw ProfileSelectionError.invalidScenario }
    guard revision.isValid else { throw ProfileSelectionError.invalidRevision }

    let seed = CanonicalHashInput.data([
      "mori-mock-profile-v1",
      scenarioID.rawValue,
      String(revision.counter),
      revision.originDeviceID,
    ])
    let digest = SHA256.hash(data: seed)
      .map { String(format: "%02x", $0) }
      .joined()
    let epoch = ProfileEpoch(revision)
    let profile = RuntimeProfile(
      id: ProfileID("mock-profile-\(digest)"),
      epoch: epoch,
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("mock-baseline-\(digest)"),
        revision: revision
      ),
      source: .mock(scenarioID: scenarioID, selectionEpoch: epoch)
    )
    return ProfileSelectionRecord(profile: profile, revision: revision)
  }
}

public enum ProfileSelectionRejection: String, Error, Codable, Sendable {
  case invalidRecord
  case conflictingRecordAtRevision
  case losingSelectionRevision
  case supersededProfileEpoch
  case profileIsNotSelected
}

public enum ProfileSelectionMergeResult: Equatable, Sendable {
  case applied(ProfileSelectionRecord)
  case duplicate(ProfileSelectionRecord)
  case rejected(ProfileSelectionRejection)
}

public enum ProfileSelectionAccess: Equatable, Sendable {
  case authorized
  case rejected(ProfileSelectionRejection)
}

/// Lamport order is the only authority for local/peer profile selection.
/// Arrival time and wall-clock time never participate in conflict resolution.
public actor ProfileSelectionAuthority {
  private var selectedRecord: ProfileSelectionRecord?

  public init(initial: ProfileSelectionRecord? = nil) throws {
    if let initial, initial.isValid == false {
      throw ProfileSelectionError.invalidProfile
    }
    selectedRecord = initial
  }

  public func current() -> ProfileSelectionRecord? {
    selectedRecord
  }

  @discardableResult
  public func merge(_ candidate: ProfileSelectionRecord) -> ProfileSelectionMergeResult {
    guard candidate.isValid else {
      return .rejected(.invalidRecord)
    }
    guard let selectedRecord else {
      self.selectedRecord = candidate
      return .applied(candidate)
    }

    if candidate.revision == selectedRecord.revision {
      guard candidate == selectedRecord else {
        return .rejected(.conflictingRecordAtRevision)
      }
      return .duplicate(selectedRecord)
    }
    guard candidate.revision > selectedRecord.revision else {
      return .rejected(.losingSelectionRevision)
    }

    self.selectedRecord = candidate
    return .applied(candidate)
  }

  public func authorize(_ profile: RuntimeProfile) -> ProfileSelectionAccess {
    guard let selectedRecord else {
      return .rejected(.profileIsNotSelected)
    }
    if profile == selectedRecord.profile {
      return .authorized
    }
    if profile.epoch < selectedRecord.profile.epoch {
      return .rejected(.supersededProfileEpoch)
    }
    return .rejected(.profileIsNotSelected)
  }

  /// Produces a storage namespace only for the authoritative selected profile.
  /// This prevents a stale, losing epoch from being reopened after offline
  /// conflict resolution.
  public func selectedNamespace(
    for requestedProfile: RuntimeProfile,
    in layout: RuntimeStorageLayout
  ) throws -> RuntimeStorageNamespace {
    switch authorize(requestedProfile) {
    case .authorized:
      return try layout.namespace(for: requestedProfile)
    case .rejected(let rejection):
      throw rejection
    }
  }
}
