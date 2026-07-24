import Foundation
import MoriDomain
import MoriPersistence

public protocol ExperienceSyncLedger: Sendable {
  func currentLedger() async throws -> ProfileLedger
  func append(_ envelope: ExperienceSyncEnvelope) async throws -> ProfileReplayResult
}

extension ProfileLedgerRepository: ExperienceSyncLedger {}

public protocol ExperienceSyncTransport: Sendable {
  func exchange(_ transferData: Data) async throws -> Data
}

public enum ExperienceSyncRunResult: Equatable, Sendable {
  case idle
  case synchronized(eventCount: Int)
}

public enum ExperienceSyncRuntimeError: Error, Equatable, Sendable {
  case invalidProfile
  case ledgerScopeMismatch
  case acknowledgementScopeMismatch
  case incompleteAcknowledgement
  case acknowledgementForUnsentEvent(ExperienceEventID)
  case invalidTerminalRejection(ExperienceEventID)
}

/// Profile-scoped automatic experience-event synchronization.
///
/// Product surfaces enqueue local derived events and lifecycle/connectivity
/// hooks call `synchronize`. There is intentionally no user-facing sync action:
/// an offline failure retains the durable outbox and a later hook retries it.
/// Conversation and social state cannot enter this runtime because its only
/// payload is the closed `ExperienceSyncEnvelope` domain type.
public actor ExperienceSyncRuntime<
  Storage: ExperienceSyncOutboxStorage,
  Ledger: ExperienceSyncLedger
> {
  private let profile: RuntimeProfile
  private let scope: ExperienceSyncScope
  private let outbox: ExperienceSyncOutbox<Storage>
  private let ledger: Ledger
  private let wireCodec: ExperienceSyncWireCodec

  public init(
    profile: RuntimeProfile,
    outboxStorage: Storage,
    ledger: Ledger,
    wireCodec: ExperienceSyncWireCodec = ExperienceSyncWireCodec()
  ) {
    self.profile = profile
    scope = ExperienceSyncScope(profile: profile)
    outbox = ExperienceSyncOutbox(storage: outboxStorage, profile: profile)
    self.ledger = ledger
    self.wireCodec = wireCodec
  }

  /// The append-only profile ledger is written first. If the process stops
  /// before the outbox write, `synchronize` reconciles the ledger into the
  /// durable delivery queue before contacting the peer.
  public func recordLocal(_ envelope: ExperienceSyncEnvelope) async throws {
    try requireValidProfile()
    guard scope.contains(envelope) else {
      throw ExperienceSyncRuntimeError.ledgerScopeMismatch
    }
    _ = try await ledger.append(envelope)
    try await outbox.reconcile([envelope])
  }

  public func pendingEventCount() async throws -> Int {
    try requireValidProfile()
    return try await outbox.pendingCount()
  }

  /// Called by foreground, connectivity, or background-refresh hooks. Exact
  /// bytes remain durable when `exchange` throws, so retry needs no UI button.
  public func synchronize<Transport: ExperienceSyncTransport>(
    using transport: Transport,
    limit: Int = 64
  ) async throws -> ExperienceSyncRunResult {
    try requireValidProfile()
    let current = try await scopedLedger()
    try await outbox.reconcile(current.envelopes)
    guard let transfer = try await outbox.pendingTransfer(limit: limit) else {
      return .idle
    }
    let sentEnvelopes = try wireCodec.decodeEnvelopes(in: transfer)
    let sentEventIDs = Set(sentEnvelopes.map(\.eventID))
    let response = try await transport.exchange(wireCodec.encode(transfer))
    let acknowledgement = try wireCodec.decodeAcknowledgement(response)
    guard acknowledgement.scope == scope else {
      throw ExperienceSyncRuntimeError.acknowledgementScopeMismatch
    }
    let resolved = Set(
      acknowledgement.eventIDs + acknowledgement.terminalRejections.map(\.eventID)
    )
    guard resolved == sentEventIDs else {
      if let unknown = resolved.first(where: { sentEventIDs.contains($0) == false }) {
        throw ExperienceSyncRuntimeError.acknowledgementForUnsentEvent(unknown)
      }
      throw ExperienceSyncRuntimeError.incompleteAcknowledgement
    }
    let localState = current.replay().state
    for rejection in acknowledgement.terminalRejections {
      guard
        let envelope = sentEnvelopes.first(where: {
          $0.eventID == rejection.eventID
        }),
        sensingEpoch(of: envelope, in: localState)
          == rejection.rejectedSensingEpoch,
        rejection.winningSensingEpoch <= localState.currentSensingEpoch
      else {
        throw ExperienceSyncRuntimeError.invalidTerminalRejection(rejection.eventID)
      }
      let localAuthorityRejects =
        rejection.rejectedSensingEpoch < localState.currentSensingEpoch
        || (rejection.rejectedSensingEpoch == localState.currentSensingEpoch
          && localState.companionSensingEnabled == false)
      guard localAuthorityRejects else {
        throw ExperienceSyncRuntimeError.invalidTerminalRejection(rejection.eventID)
      }
    }
    try await outbox.acknowledge(
      acknowledgement,
      sentEventIDs: sentEventIDs
    )
    return .synchronized(eventCount: acknowledgement.eventIDs.count)
  }

  /// Preflights the complete transfer, then uses the repository's serialized
  /// append path. An interrupted partial delivery is never acknowledged and
  /// the sender retries the same IDs; exact duplicates are idempotent.
  public func receive(_ transferData: Data) async throws -> Data {
    try requireValidProfile()
    let transfer = try wireCodec.decodeTransfer(transferData)
    guard transfer.scope == scope else {
      throw ExperienceSyncRuntimeError.ledgerScopeMismatch
    }
    let envelopes = try wireCodec.decodeEnvelopes(in: transfer)
    var candidate = try await scopedLedger()
    let authority = candidate.replay().state
    let incomingPassiveEpochs = unambiguousPassiveEpochs(in: envelopes)
    var accepted: [ExperienceSyncEnvelope] = []
    var terminalRejections: [ExperienceSyncTerminalRejection] = []
    for envelope in envelopes.sorted(by: ProfileLedger.canonicalOrder) {
      if let rejectedEpoch = sensingEpoch(
        of: envelope,
        in: authority,
        incomingPassiveEpochs: incomingPassiveEpochs
      ),
        rejectedEpoch < authority.currentSensingEpoch
          || (rejectedEpoch == authority.currentSensingEpoch
            && authority.companionSensingEnabled == false)
      {
        terminalRejections.append(
          ExperienceSyncTerminalRejection(
            eventID: envelope.eventID,
            reason: .supersededSensingEpoch,
            rejectedSensingEpoch: rejectedEpoch,
            winningSensingEpoch: authority.currentSensingEpoch,
            companionSensingEnabled: authority.companionSensingEnabled
          )
        )
        continue
      }
      do {
        try candidate.append(envelope)
        accepted.append(envelope)
      } catch ProfileLedgerError.invalidEnvelope(
        let eventID,
        MoriDomainRejection.sensingEpochMismatch
      ) {
        throw ProfileLedgerError.invalidEnvelope(
          eventID,
          .sensingEpochMismatch
        )
      }
    }
    for envelope in accepted {
      _ = try await ledger.append(envelope)
    }
    try await outbox.markPeerDelivered(envelopes)
    return try wireCodec.encode(
      ExperienceSyncAcknowledgement(
        scope: scope,
        eventIDs: accepted.map(\.eventID),
        terminalRejections: terminalRejections
      )
    )
  }

  public func currentReplay() async throws -> ProfileReplayResult {
    try await scopedLedger().replay()
  }

  private func scopedLedger() async throws -> ProfileLedger {
    let current = try await ledger.currentLedger()
    guard current.initialState.runtimeProfile == profile else {
      throw ExperienceSyncRuntimeError.ledgerScopeMismatch
    }
    return current
  }

  private func requireValidProfile() throws {
    guard profile.isValid, scope.isValid else {
      throw ExperienceSyncRuntimeError.invalidProfile
    }
  }

  private func sensingEpoch(
    of envelope: ExperienceSyncEnvelope,
    in state: ProfileState,
    incomingPassiveEpochs: [EventID: SensingEpoch] = [:]
  ) -> SensingEpoch? {
    switch envelope.payload {
    case .derivedFact(let fact):
      if case .companion(let epoch) = fact.authorization { epoch } else { nil }
    case .passiveEvent(let event):
      event.sensingEpoch
    case .passiveEventTransition(let transition):
      state.passiveEvents.first {
        $0.header.recordID == transition.eventID
      }?.sensingEpoch ?? incomingPassiveEpochs[transition.eventID]
    case .task(let task):
      state.passiveEvents.first {
        $0.header.recordID == task.sourceEventID
      }?.sensingEpoch ?? incomingPassiveEpochs[task.sourceEventID]
    default:
      nil
    }
  }

  private func unambiguousPassiveEpochs(
    in envelopes: [ExperienceSyncEnvelope]
  ) -> [EventID: SensingEpoch] {
    var epochs: [EventID: SensingEpoch] = [:]
    var ambiguous: Set<EventID> = []
    for envelope in envelopes {
      guard case .passiveEvent(let event) = envelope.payload else { continue }
      let eventID = event.header.recordID
      if let existing = epochs[eventID], existing != event.sensingEpoch {
        epochs.removeValue(forKey: eventID)
        ambiguous.insert(eventID)
      } else if ambiguous.contains(eventID) == false {
        epochs[eventID] = event.sensingEpoch
      }
    }
    return epochs
  }
}
