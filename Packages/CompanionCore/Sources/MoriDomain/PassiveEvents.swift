import Foundation

public enum EvidenceKind: String, CaseIterable, Hashable, Codable, Sendable {
  case stepSummary
  case sleepDuration
  case broadMotion
  case approvedPlaceCategory
  case foregroundInteraction
}

public enum BroadMotion: String, CaseIterable, Hashable, Codable, Sendable {
  case stationary
  case walking
  case running
  case cycling
  case automotive
  case unknown
}

public enum ApprovedPlaceCategory: String, CaseIterable, Hashable, Codable, Sendable {
  case home
  case work
  case park
  case transit
  case other
}

public enum DerivedFactValue: Hashable, Codable, Sendable {
  case stepTotal(Int)
  case sleepDuration(TimeInterval)
  case broadMotion(BroadMotion)
  case approvedPlaceCategory(ApprovedPlaceCategory)
  case foregroundInteraction

  public var kind: EvidenceKind {
    switch self {
    case .stepTotal: .stepSummary
    case .sleepDuration: .sleepDuration
    case .broadMotion: .broadMotion
    case .approvedPlaceCategory: .approvedPlaceCategory
    case .foregroundInteraction: .foregroundInteraction
    }
  }
}

public enum EvidenceProvenance: String, CaseIterable, Hashable, Codable, Sendable {
  case healthSummary
  case motionClassifier
  case coarsePlaceClassifier
  case foregroundInteraction
  case deterministicMock
}

/// Display facts can keep the Watch face informative while passive
/// companionship is disabled. Only sensing-epoch-authorized facts may create
/// passive events and their downstream tasks, letters, or memories.
public enum EvidenceAuthorization: Hashable, Codable, Sendable {
  case displayOnly
  case companion(SensingEpoch)
}

public struct DerivedFactRecord: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<EvidenceID>
  public let observedAt: Date
  public let freshUntil: Date
  public let value: DerivedFactValue
  public let provenance: EvidenceProvenance
  public let authorization: EvidenceAuthorization

  public init(
    header: ProfileScopedRecordHeader<EvidenceID>,
    observedAt: Date,
    freshUntil: Date,
    value: DerivedFactValue,
    provenance: EvidenceProvenance,
    authorization: EvidenceAuthorization = .displayOnly
  ) {
    self.header = header
    self.observedAt = observedAt
    self.freshUntil = freshUntil
    self.value = value
    self.provenance = provenance
    self.authorization = authorization
  }

  public func validate(in profile: RuntimeProfile) -> MoriDomainRejection? {
    guard header.schemaVersion == 1 else { return .invalidSchema }
    guard header.recordID.isValid else { return .invalidIdentifier }
    guard header.profileID == profile.id else { return .profileMismatch }
    guard header.profileEpoch == profile.epoch else { return .profileEpochMismatch }
    guard header.deletionEpoch == profile.deletionEpoch else {
      return .deletionEpochMismatch
    }
    guard freshUntil >= observedAt else { return .invalidRecord }
    switch value {
    case .stepTotal(let value):
      guard value >= 0 else { return .invalidRecord }
    case .sleepDuration(let value):
      guard value >= 0, value.isFinite else { return .invalidRecord }
    default:
      break
    }
    switch profile.source {
    case .real:
      guard provenance != .deterministicMock else { return .profileMismatch }
      let expectedProvenance: EvidenceProvenance =
        switch value {
        case .stepTotal, .sleepDuration:
          .healthSummary
        case .broadMotion:
          .motionClassifier
        case .approvedPlaceCategory:
          .coarsePlaceClassifier
        case .foregroundInteraction:
          .foregroundInteraction
        }
      guard provenance == expectedProvenance else { return .invalidRecord }
    case .mock:
      guard provenance == .deterministicMock else { return .profileMismatch }
    }
    if case .companion(let sensingEpoch) = authorization {
      guard sensingEpoch.isValid else { return .invalidRecord }
    }
    return nil
  }

  public func authorizesCompanionUse(in sensingEpoch: SensingEpoch) -> Bool {
    authorization == .companion(sensingEpoch)
  }

  public func isUsable(at date: Date, in profile: RuntimeProfile) -> Bool {
    validate(in: profile) == nil
      && date >= observedAt
      && date <= freshUntil
  }
}

public struct EvidenceReference: Hashable, Codable, Sendable {
  public let id: EvidenceID
  public let kind: EvidenceKind

  public init(id: EvidenceID, kind: EvidenceKind) {
    self.id = id
    self.kind = kind
  }
}

public enum ConfidenceBand: Int, CaseIterable, Hashable, Codable, Sendable, Comparable {
  case low = 0
  case medium = 1
  case high = 2
  case exact = 3

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var permitsVisibleClaim: Bool { self != .low }
}

public enum PassiveEventKind: String, CaseIterable, Hashable, Codable, Sendable {
  case sharedWalk
  case fastPace
  case pausedTogether
  case arrivedAtApprovedPlace
  case sleepReflection
  case foregroundGreeting
}

public enum MemoryEligibility: String, Hashable, Codable, Sendable {
  case ineligible
  case eligible
}

public enum ReminderState: Hashable, Codable, Sendable {
  case pending
  case presented(at: Date)
  case expired(at: Date)
  case replaced(by: EventID, at: Date)

  public var isTerminal: Bool {
    if case .pending = self { return false }
    return true
  }
}

public struct PassiveCompanionEvent: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<EventID>
  public let sensingEpoch: SensingEpoch
  public let kind: PassiveEventKind
  public let observedAt: Date
  public let confidence: ConfidenceBand
  public let evidence: [EvidenceReference]
  public let presentationDeadline: Date?
  public let replacementKey: String?
  public let taskCooldownKey: TaskCooldownKey?
  public let memoryEligibility: MemoryEligibility
  public let sceneID: String?
  public let moriActionID: String
  public private(set) var reminderState: ReminderState
  public private(set) var reminderRevision: LamportRevision

  public init(
    header: ProfileScopedRecordHeader<EventID>,
    sensingEpoch: SensingEpoch,
    kind: PassiveEventKind,
    observedAt: Date,
    confidence: ConfidenceBand,
    evidence: [EvidenceReference],
    presentationDeadline: Date?,
    replacementKey: String?,
    taskCooldownKey: TaskCooldownKey?,
    memoryEligibility: MemoryEligibility,
    sceneID: String?,
    moriActionID: String,
    reminderState: ReminderState = .pending,
    reminderRevision: LamportRevision
  ) {
    self.header = header
    self.sensingEpoch = sensingEpoch
    self.kind = kind
    self.observedAt = observedAt
    self.confidence = confidence
    self.evidence = evidence
    self.presentationDeadline = presentationDeadline
    self.replacementKey = replacementKey
    self.taskCooldownKey = taskCooldownKey
    self.memoryEligibility = memoryEligibility
    self.sceneID = sceneID
    self.moriActionID = moriActionID
    self.reminderState = reminderState
    self.reminderRevision = reminderRevision
  }

  public var permitsVisibleClaim: Bool { confidence.permitsVisibleClaim }

  public func validate(in profile: RuntimeProfile, sensingEpoch currentSensingEpoch: SensingEpoch)
    -> MoriDomainRejection?
  {
    guard header.schemaVersion == 1 else { return .invalidSchema }
    guard header.recordID.isValid, moriActionID.isEmpty == false, reminderRevision.isValid else {
      return .invalidIdentifier
    }
    guard header.profileID == profile.id else { return .profileMismatch }
    guard header.profileEpoch == profile.epoch else { return .profileEpochMismatch }
    guard header.deletionEpoch == profile.deletionEpoch else { return .deletionEpochMismatch }
    guard sensingEpoch == currentSensingEpoch else { return .sensingEpochMismatch }
    guard confidence.permitsVisibleClaim else { return .lowConfidence }
    guard evidence.isEmpty == false, evidence.allSatisfy({ $0.id.isValid }) else {
      return .invalidRecord
    }
    if let deadline = presentationDeadline, deadline < observedAt {
      return .invalidRecord
    }
    return nil
  }

  public mutating func apply(
    _ transition: PassiveEventTransition,
    in profile: RuntimeProfile
  ) -> MutationResult {
    guard transition.header.schemaVersion == 1 else { return .rejected(.invalidSchema) }
    guard transition.header.scopeMatches(profile), header.scopeMatches(profile) else {
      return .rejected(.profileMismatch)
    }
    guard transition.eventID == header.recordID else { return .rejected(.invalidRecord) }
    guard transition.revision.isValid else { return .rejected(.invalidIdentifier) }
    switch transition.state {
    case .pending:
      return .rejected(.illegalTransition)
    case .replaced(let eventID, _):
      guard eventID.isValid else { return .rejected(.invalidIdentifier) }
    case .presented, .expired:
      break
    }
    guard transition.revision > reminderRevision else {
      return transition.revision == reminderRevision && transition.state == reminderState
        ? .duplicate
        : .rejected(.conflictingDuplicate)
    }
    guard case .pending = reminderState else {
      // The first canonical terminal decision is authoritative. A different,
      // well-formed terminal transition is a consumed loser, not a dependency
      // that should remain in the retry queue forever.
      return .duplicate
    }
    reminderState = transition.state
    reminderRevision = transition.revision
    return .applied
  }

  /// A newer sensing preference epoch authoritatively invalidates every pending
  /// glance produced by an older sensing epoch. Its preference revision is a
  /// separate causal channel, so it must not be blocked by a numerically newer
  /// reminder transition revision from the superseded epoch.
  mutating func expireForSupersededSensingEpoch(
    _ currentSensingEpoch: SensingEpoch,
    at date: Date
  ) -> MutationResult {
    guard sensingEpoch < currentSensingEpoch else {
      return .rejected(.sensingEpochMismatch)
    }
    guard case .pending = reminderState else { return .duplicate }
    reminderState = .expired(at: date)
    if reminderRevision < currentSensingEpoch.revision {
      reminderRevision = currentSensingEpoch.revision
    }
    return .applied
  }
}

public struct PassiveEventTransition: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<EventTransitionID>
  public let eventID: EventID
  public let revision: LamportRevision
  public let state: ReminderState

  public init(
    header: ProfileScopedRecordHeader<EventTransitionID>,
    eventID: EventID,
    revision: LamportRevision,
    state: ReminderState
  ) {
    self.header = header
    self.eventID = eventID
    self.revision = revision
    self.state = state
  }
}
