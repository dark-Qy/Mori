import Foundation

public protocol MoriIdentifierTag: Sendable {}

public struct StableIdentifier<Tag: MoriIdentifierTag>:
  RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
  public var isValid: Bool { !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public enum ProfileIDTag: MoriIdentifierTag {}
public enum MockScenarioIDTag: MoriIdentifierTag {}
public enum DeletionRequestIDTag: MoriIdentifierTag {}
public enum EvidenceIDTag: MoriIdentifierTag {}
public enum EventIDTag: MoriIdentifierTag {}
public enum EventTransitionIDTag: MoriIdentifierTag {}
public enum TaskIDTag: MoriIdentifierTag {}
public enum TaskTransitionIDTag: MoriIdentifierTag {}
public enum TaskCooldownIDTag: MoriIdentifierTag {}
public enum TaskCooldownKeyTag: MoriIdentifierTag {}
public enum TaskSettlementIDTag: MoriIdentifierTag {}
public enum CoinLedgerIDTag: MoriIdentifierTag {}
public enum CoinTransactionIDTag: MoriIdentifierTag {}
public enum MemoryIDTag: MoriIdentifierTag {}
public enum MemoryTransitionIDTag: MoriIdentifierTag {}
public enum LetterIDTag: MoriIdentifierTag {}
public enum LetterTransitionIDTag: MoriIdentifierTag {}
public enum ConversationIDTag: MoriIdentifierTag {}
public enum ConversationRecordIDTag: MoriIdentifierTag {}
public enum ConversationTransitionIDTag: MoriIdentifierTag {}
public enum CosmeticIDTag: MoriIdentifierTag {}
public enum CollectionIDTag: MoriIdentifierTag {}
public enum CollectionOwnershipIDTag: MoriIdentifierTag {}
public enum CollectionTransitionIDTag: MoriIdentifierTag {}
public enum IdentitySelectionIDTag: MoriIdentifierTag {}
public enum ExperienceEventIDTag: MoriIdentifierTag {}

public typealias ProfileID = StableIdentifier<ProfileIDTag>
public typealias MockScenarioID = StableIdentifier<MockScenarioIDTag>
public typealias DeletionRequestID = StableIdentifier<DeletionRequestIDTag>
public typealias EvidenceID = StableIdentifier<EvidenceIDTag>
public typealias EventID = StableIdentifier<EventIDTag>
public typealias EventTransitionID = StableIdentifier<EventTransitionIDTag>
public typealias TaskID = StableIdentifier<TaskIDTag>
public typealias TaskTransitionID = StableIdentifier<TaskTransitionIDTag>
public typealias TaskCooldownID = StableIdentifier<TaskCooldownIDTag>
public typealias TaskCooldownKey = StableIdentifier<TaskCooldownKeyTag>
public typealias TaskSettlementID = StableIdentifier<TaskSettlementIDTag>
public typealias CoinLedgerID = StableIdentifier<CoinLedgerIDTag>
public typealias CoinTransactionID = StableIdentifier<CoinTransactionIDTag>
public typealias MemoryID = StableIdentifier<MemoryIDTag>
public typealias MemoryTransitionID = StableIdentifier<MemoryTransitionIDTag>
public typealias LetterID = StableIdentifier<LetterIDTag>
public typealias LetterTransitionID = StableIdentifier<LetterTransitionIDTag>
public typealias ConversationID = StableIdentifier<ConversationIDTag>
public typealias ConversationRecordID = StableIdentifier<ConversationRecordIDTag>
public typealias ConversationTransitionID = StableIdentifier<ConversationTransitionIDTag>
public typealias CosmeticID = StableIdentifier<CosmeticIDTag>
public typealias CollectionID = StableIdentifier<CollectionIDTag>
public typealias CollectionOwnershipID = StableIdentifier<CollectionOwnershipIDTag>
public typealias CollectionTransitionID = StableIdentifier<CollectionTransitionIDTag>
public typealias IdentitySelectionID = StableIdentifier<IdentitySelectionIDTag>
public typealias ExperienceEventID = StableIdentifier<ExperienceEventIDTag>

public struct LamportRevision: Hashable, Codable, Sendable, Comparable {
  public let counter: UInt64
  public let originDeviceID: String

  public init(counter: UInt64, originDeviceID: String) {
    self.counter = counter
    self.originDeviceID = originDeviceID
  }

  public var isValid: Bool {
    !originDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.counter != rhs.counter {
      return lhs.counter < rhs.counter
    }
    return lhs.originDeviceID < rhs.originDeviceID
  }
}

public protocol MoriEpochTag: Sendable {}
public enum ProfileEpochTag: MoriEpochTag {}
public enum SensingEpochTag: MoriEpochTag {}

public struct LogicalEpoch<Tag: MoriEpochTag>: Hashable, Codable, Sendable, Comparable {
  public let revision: LamportRevision

  public init(_ revision: LamportRevision) {
    self.revision = revision
  }

  public var isValid: Bool { revision.isValid }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.revision < rhs.revision
  }
}

public typealias ProfileEpoch = LogicalEpoch<ProfileEpochTag>
public typealias SensingEpoch = LogicalEpoch<SensingEpochTag>

/// A deletion fence needs both logical ordering and stable retry identity.
/// Retrying the same request preserves this full value across devices.
public struct DeletionEpoch: Hashable, Codable, Sendable, Comparable {
  public let requestID: DeletionRequestID
  public let revision: LamportRevision

  public init(requestID: DeletionRequestID, revision: LamportRevision) {
    self.requestID = requestID
    self.revision = revision
  }

  public var isValid: Bool {
    requestID.isValid && revision.isValid
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.revision != rhs.revision {
      return lhs.revision < rhs.revision
    }
    return lhs.requestID < rhs.requestID
  }
}

public struct ProfileScopedRecordHeader<RecordID: Hashable & Codable & Sendable>:
  Hashable, Codable, Sendable
{
  public let schemaVersion: UInt16
  public let recordID: RecordID
  public let profileID: ProfileID
  public let profileEpoch: ProfileEpoch
  public let deletionEpoch: DeletionEpoch

  public init(
    schemaVersion: UInt16 = 1,
    recordID: RecordID,
    profileID: ProfileID,
    profileEpoch: ProfileEpoch,
    deletionEpoch: DeletionEpoch
  ) {
    self.schemaVersion = schemaVersion
    self.recordID = recordID
    self.profileID = profileID
    self.profileEpoch = profileEpoch
    self.deletionEpoch = deletionEpoch
  }

  public func scopeMatches(_ profile: RuntimeProfile) -> Bool {
    profileID == profile.id
      && profileEpoch == profile.epoch
      && deletionEpoch == profile.deletionEpoch
  }
}

public enum RuntimeProfileSource: Hashable, Codable, Sendable {
  case real
  case mock(scenarioID: MockScenarioID, selectionEpoch: ProfileEpoch)
}

public struct RuntimeProfile: Hashable, Codable, Sendable {
  public let id: ProfileID
  public let epoch: ProfileEpoch
  public let deletionEpoch: DeletionEpoch
  public let source: RuntimeProfileSource

  public init(
    id: ProfileID,
    epoch: ProfileEpoch,
    deletionEpoch: DeletionEpoch,
    source: RuntimeProfileSource
  ) {
    self.id = id
    self.epoch = epoch
    self.deletionEpoch = deletionEpoch
    self.source = source
  }

  public var isValid: Bool {
    guard id.isValid, epoch.isValid, deletionEpoch.isValid else { return false }
    switch source {
    case .real:
      return true
    case .mock(let scenarioID, let selectionEpoch):
      return scenarioID.isValid && selectionEpoch == epoch
    }
  }

  public var isMock: Bool {
    if case .mock = source { return true }
    return false
  }
}

public enum MoriDomainRejection: String, Error, Hashable, Codable, Sendable {
  case invalidSchema
  case invalidIdentifier
  case invalidRecord
  case profileMismatch
  case profileEpochMismatch
  case deletionEpochMismatch
  case sensingEpochMismatch
  case conflictingDuplicate
  case illegalTransition
  case lowConfidence
  case cooldownActive
  case invisibleManualTask
  case completionNotAllowed
  case insufficientCoins
  case itemAlreadyOwned
  case itemNotOwned
  case invalidRewardTier
  case invalidPayload
  case tombstoneMismatch
  case sealedRecord
  case deletedRecord
}

public enum MutationResult: Hashable, Codable, Sendable {
  case applied
  case duplicate
  case rejected(MoriDomainRejection)
}

public enum MoriIdentity: String, CaseIterable, Hashable, Codable, Sendable {
  case penguin
  case polarBear
}

public enum MoriTone: String, CaseIterable, Hashable, Codable, Sendable {
  case gentle
  case playful
  case quiet
}
