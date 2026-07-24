import Foundation
import MoriDomain

public enum ProfileLedgerError: Error, Equatable, Sendable {
  case unsupportedLedgerSchema(UInt16)
  case invalidInitialState(MoriDomainRejection)
  case initialStateContainsExperienceEvents
  case initialStateContainsProductRecords
  case invalidEnvelope(ExperienceEventID, MoriDomainRejection)
  case envelopeProfileMismatch(ExperienceEventID)
  case conflictingEnvelopeID(ExperienceEventID)
}

public struct ProfileReplayRejection: Codable, Equatable, Sendable {
  public let eventID: ExperienceEventID
  public let reason: MoriDomainRejection

  public init(eventID: ExperienceEventID, reason: MoriDomainRejection) {
    self.eventID = eventID
    self.reason = reason
  }
}

public struct ProfileReplayResult: Codable, Equatable, Sendable {
  public let state: ProfileState
  public let unresolved: [ProfileReplayRejection]

  public init(state: ProfileState, unresolved: [ProfileReplayRejection]) {
    self.state = state
    self.unresolved = unresolved
  }
}

/// An append-only, profile-scoped source of truth. Wall-clock timestamps never
/// decide replay order. Missing dependencies remain unresolved and are retried
/// automatically whenever another envelope is appended.
public struct ProfileLedger: Codable, Equatable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public private(set) var schemaVersion: UInt16
  public private(set) var initialState: ProfileState
  public private(set) var envelopes: [ExperienceSyncEnvelope]

  public init(
    initialState: ProfileState,
    envelopes: [ExperienceSyncEnvelope] = []
  ) throws {
    schemaVersion = Self.currentSchemaVersion
    guard let rejection = initialState.validate() else {
      guard initialState.experienceLedger.isEmpty else {
        throw ProfileLedgerError.initialStateContainsExperienceEvents
      }
      guard
        initialState.derivedFacts.isEmpty,
        initialState.passiveEvents.isEmpty,
        initialState.tasks.isEmpty,
        initialState.cooldowns.isEmpty,
        initialState.coinLedger.transactions.isEmpty,
        initialState.collection.ownership.isEmpty,
        initialState.collection.equipped.isEmpty,
        initialState.memories.isEmpty,
        initialState.letters.isEmpty,
        initialState.conversation.isEmpty
      else {
        throw ProfileLedgerError.initialStateContainsProductRecords
      }
      self.initialState = initialState
      self.envelopes = []
      for envelope in envelopes.sorted(by: Self.canonicalOrder) {
        try appendAcceptedLedgerEnvelope(envelope)
      }
      return
    }
    throw ProfileLedgerError.invalidInitialState(rejection)
  }

  public mutating func append(_ envelope: ExperienceSyncEnvelope) throws {
    try validateEnvelopeForStorage(envelope)
    if let existing = envelopes.first(where: { $0.eventID == envelope.eventID }) {
      guard existing == envelope else {
        throw ProfileLedgerError.conflictingEnvelopeID(envelope.eventID)
      }
      return
    }
    if let rejection = incomingAdmissionRejection(for: envelope) {
      throw ProfileLedgerError.invalidEnvelope(envelope.eventID, rejection)
    }
    envelopes.append(envelope)
    envelopes.sort(by: Self.canonicalOrder)
  }

  /// Advances the persisted sensing authority without rewriting accepted
  /// product history. Subsequent incoming envelopes must use this exact epoch;
  /// replay continues to reconstruct records accepted by earlier epochs.
  @discardableResult
  public mutating func setCompanionSensing(
    enabled: Bool,
    epoch: SensingEpoch,
    effectiveAt: Date
  ) -> MutationResult {
    var baseline = initialState
    let result = baseline.setCompanionSensing(
      enabled: enabled,
      epoch: epoch,
      effectiveAt: effectiveAt
    )
    if case .applied = result {
      initialState = baseline
    }
    return result
  }

  private mutating func appendAcceptedLedgerEnvelope(
    _ envelope: ExperienceSyncEnvelope
  ) throws {
    try validateEnvelopeForStorage(envelope)
    if let existing = envelopes.first(where: { $0.eventID == envelope.eventID }) {
      guard existing == envelope else {
        throw ProfileLedgerError.conflictingEnvelopeID(envelope.eventID)
      }
      return
    }
    envelopes.append(envelope)
    envelopes.sort(by: Self.canonicalOrder)
  }

  private func validateEnvelopeForStorage(
    _ envelope: ExperienceSyncEnvelope
  ) throws {
    if let rejection = envelope.validate() {
      throw ProfileLedgerError.invalidEnvelope(envelope.eventID, rejection)
    }
    guard
      envelope.profileID == initialState.runtimeProfile.id,
      envelope.profileEpoch == initialState.runtimeProfile.epoch,
      envelope.deletionEpoch == initialState.runtimeProfile.deletionEpoch,
      envelope.profileSource == initialState.runtimeProfile.source
    else {
      throw ProfileLedgerError.envelopeProfileMismatch(envelope.eventID)
    }
  }

  private func incomingAdmissionRejection(
    for envelope: ExperienceSyncEnvelope
  ) -> MoriDomainRejection? {
    let replayedState = replay().state
    switch envelope.payload {
    case .derivedFact(let record):
      guard case .companion(let epoch) = record.authorization else { return nil }
      guard
        replayedState.companionSensingEnabled,
        epoch == replayedState.currentSensingEpoch
      else {
        return .sensingEpochMismatch
      }
    case .passiveEvent(let event):
      guard
        replayedState.companionSensingEnabled,
        event.sensingEpoch == replayedState.currentSensingEpoch
      else {
        return .sensingEpochMismatch
      }
      let knownEvidence = event.evidence.allSatisfy { reference in
        replayedState.derivedFacts.contains {
          $0.header.recordID == reference.id
        }
      }
      if knownEvidence {
        var candidateState = replayedState
        if case .rejected(let rejection) = ProfileReducer.apply(
          envelope,
          to: &candidateState
        ) {
          return rejection
        }
      }
    case .passiveEventTransition(let transition):
      guard
        let source = replayedState.passiveEvents.first(where: {
          $0.header.recordID == transition.eventID
        })
      else {
        return nil
      }
      if source.sensingEpoch < replayedState.currentSensingEpoch,
        case .presented = transition.state
      {
        return .sensingEpochMismatch
      }
    case .task(let task):
      guard
        let source = replayedState.passiveEvents.first(where: {
          $0.header.recordID == task.sourceEventID
        })
      else {
        return nil
      }
      guard
        replayedState.companionSensingEnabled,
        source.sensingEpoch == replayedState.currentSensingEpoch
      else {
        return .sensingEpochMismatch
      }
    default:
      break
    }
    return nil
  }

  public func replay() -> ProfileReplayResult {
    var state = cleanInitialState()
    var pending = envelopes.sorted(by: Self.canonicalOrder)
    var lastReasons: [ExperienceEventID: MoriDomainRejection] = [:]

    // A later envelope may supply a record referenced by an earlier transition.
    // Fixed-point replay handles offline reordering without letting arrival time
    // become authority. Each successful pass removes at least one item.
    while pending.isEmpty == false {
      var nextPending: [ExperienceSyncEnvelope] = []
      var madeProgress = false

      for envelope in pending {
        switch ProfileReducer.replayAcceptedLedgerEnvelope(envelope, to: &state) {
        case .applied, .duplicate:
          lastReasons.removeValue(forKey: envelope.eventID)
          madeProgress = true
        case .rejected(let reason):
          lastReasons[envelope.eventID] = reason
          nextPending.append(envelope)
        }
      }

      pending = nextPending
      if madeProgress == false { break }
    }

    ProfileReducer.finalizeAcceptedLedgerReplay(&state)
    let unresolved = pending.map {
      ProfileReplayRejection(
        eventID: $0.eventID,
        reason: lastReasons[$0.eventID] ?? .invalidRecord
      )
    }
    return ProfileReplayResult(state: state, unresolved: unresolved)
  }

  public static func canonicalOrder(
    _ lhs: ExperienceSyncEnvelope,
    _ rhs: ExperienceSyncEnvelope
  ) -> Bool {
    if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
    if lhs.originSequence != rhs.originSequence {
      return lhs.originSequence < rhs.originSequence
    }
    return lhs.eventID < rhs.eventID
  }

  private func cleanInitialState() -> ProfileState {
    ProfileState(
      header: initialState.header,
      runtimeProfile: initialState.runtimeProfile,
      companionSensingEnabled: initialState.companionSensingEnabled,
      currentSensingEpoch: initialState.currentSensingEpoch,
      selectedIdentity: initialState.selectedIdentity,
      identityRevision: initialState.identityRevision,
      tone: initialState.tone,
      derivedFacts: initialState.derivedFacts,
      passiveEvents: initialState.passiveEvents,
      tasks: initialState.tasks,
      cooldowns: initialState.cooldowns,
      coinLedger: initialState.coinLedger,
      collection: initialState.collection,
      memories: initialState.memories,
      letters: initialState.letters,
      conversation: initialState.conversation,
      experienceLedger: []
    )
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case initialState
    case envelopes
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(UInt16.self, forKey: .schemaVersion)
    guard version == Self.currentSchemaVersion else {
      throw ProfileLedgerError.unsupportedLedgerSchema(version)
    }
    let initialState = try container.decode(ProfileState.self, forKey: .initialState)
    let envelopes = try container.decode([ExperienceSyncEnvelope].self, forKey: .envelopes)
    try self.init(initialState: initialState, envelopes: envelopes)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
    try container.encode(initialState, forKey: .initialState)
    try container.encode(envelopes.sorted(by: Self.canonicalOrder), forKey: .envelopes)
  }
}

public struct ProfileLedgerCodec: Sendable {
  private let codec: CanonicalJSONCodec

  public init(codec: CanonicalJSONCodec = CanonicalJSONCodec()) {
    self.codec = codec
  }

  public func encode(_ ledger: ProfileLedger) throws -> Data {
    try codec.encode(ledger)
  }

  public func decode(_ data: Data) throws -> ProfileLedger {
    try codec.decode(ProfileLedger.self, from: data)
  }
}
