import AppleAdapters
import Foundation

public enum EncounterPhase: String, Codable, Equatable, Sendable {
  case idle
  case rendezvous
  case ranging
  case preview
  case awaitingConfirmations
  case completed
  case failed
  case cancelled
}

public struct EncounterFailure: Codable, Equatable, Sendable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct Encounter: Codable, Equatable, Sendable {
  public let id: String
  public let localParticipantID: String
  public let peerCard: PublicPetCardV1
  public let completedAt: Date

  public init(
    id: String,
    localParticipantID: String,
    peerCard: PublicPetCardV1,
    completedAt: Date
  ) {
    self.id = id
    self.localParticipantID = localParticipantID
    self.peerCard = peerCard
    self.completedAt = completedAt
  }
}

public struct EncounterState: Equatable, Sendable {
  public internal(set) var phase: EncounterPhase
  public internal(set) var sessionID: String?
  public internal(set) var encounterID: String?
  public internal(set) var transferRole: PetTransferAnimationRole?
  public internal(set) var peerCard: PublicPetCardV1?
  public internal(set) var proximitySatisfied: Bool
  public internal(set) var localConfirmed: Bool
  public internal(set) var peerConfirmed: Bool
  public internal(set) var encounter: Encounter?
  public internal(set) var transferAnimationCue: PetTransferAnimationCue?
  public internal(set) var failure: EncounterFailure?

  public init(
    phase: EncounterPhase = .idle,
    sessionID: String? = nil,
    encounterID: String? = nil,
    transferRole: PetTransferAnimationRole? = nil,
    peerCard: PublicPetCardV1? = nil,
    proximitySatisfied: Bool = false,
    localConfirmed: Bool = false,
    peerConfirmed: Bool = false,
    encounter: Encounter? = nil,
    transferAnimationCue: PetTransferAnimationCue? = nil,
    failure: EncounterFailure? = nil
  ) {
    self.phase = phase
    self.sessionID = sessionID
    self.encounterID = encounterID
    self.transferRole = transferRole
    self.peerCard = peerCard
    self.proximitySatisfied = proximitySatisfied
    self.localConfirmed = localConfirmed
    self.peerConfirmed = peerConfirmed
    self.encounter = encounter
    self.transferAnimationCue = transferAnimationCue
    self.failure = failure
  }
}

public struct ProximityStabilityPolicy: Equatable, Sendable {
  public let maximumDistanceMeters: Double
  public let requiredConsecutiveSamples: Int
  public let maximumSampleAge: TimeInterval
  public let maximumGapBetweenSamples: TimeInterval

  public init(
    maximumDistanceMeters: Double = 0.15,
    requiredConsecutiveSamples: Int = 3,
    maximumSampleAge: TimeInterval = 1,
    maximumGapBetweenSamples: TimeInterval = 0.75
  ) {
    precondition(maximumDistanceMeters >= 0)
    precondition(requiredConsecutiveSamples > 0)
    precondition(maximumSampleAge >= 0)
    precondition(maximumGapBetweenSamples >= 0)
    self.maximumDistanceMeters = maximumDistanceMeters
    self.requiredConsecutiveSamples = requiredConsecutiveSamples
    self.maximumSampleAge = maximumSampleAge
    self.maximumGapBetweenSamples = maximumGapBetweenSamples
  }
}

public enum EncounterTransitionError: Error, Equatable, Sendable {
  case invalidPhase(expected: [EncounterPhase], actual: EncounterPhase)
  case proximityNotSatisfied
  case missingPeerCard
  case missingEncounterID
  case transferAnimationIdentityMismatch
}

/// A deterministic reducer for the complete touch-exchange lifecycle.
///
/// Network and Nearby Interaction callbacks are intentionally kept outside this
/// value so every transition is replayable in tests.
public struct EncounterStateMachine: Sendable {
  public private(set) var state: EncounterState
  public let configuration: ProximityStabilityPolicy

  private var localParticipantID: String?
  private var consecutiveSamples = 0
  private var lastAcceptedSampleAt: Date?

  public init(
    configuration: ProximityStabilityPolicy = ProximityStabilityPolicy()
  ) {
    state = EncounterState()
    self.configuration = configuration
  }

  public mutating func startRendezvous(
    participantID: String,
    sessionID: String? = nil
  ) {
    state = EncounterState(phase: .rendezvous, sessionID: sessionID)
    localParticipantID = participantID
    resetMeasurements()
  }

  public mutating func updateRendezvous(sessionID: String, encounterID: String? = nil) throws {
    try requirePhase([.rendezvous])
    state.sessionID = sessionID
    if let encounterID {
      state.encounterID = encounterID
    }
  }

  public mutating func didMatch(
    sessionID: String,
    encounterID: String? = nil,
    transferRole: PetTransferAnimationRole? = nil
  ) throws {
    try requirePhase([.rendezvous, .ranging, .preview, .awaitingConfirmations])
    state.sessionID = sessionID
    state.encounterID = encounterID
    state.transferRole = transferRole
    state.peerCard = nil
    state.localConfirmed = false
    state.peerConfirmed = false
    state.encounter = nil
    state.transferAnimationCue = nil
    state.failure = nil
    state.phase = .ranging
    resetMeasurements()
  }

  /// Returns the current candidate to discovery without ending the local
  /// rendezvous session. Candidate-scoped measurements, cards, and consent are
  /// always discarded.
  public mutating func didLoseCandidate() throws {
    try requirePhase([.ranging, .preview, .awaitingConfirmations])
    state.phase = .rendezvous
    state.encounterID = nil
    state.transferRole = nil
    state.peerCard = nil
    state.localConfirmed = false
    state.peerConfirmed = false
    state.encounter = nil
    state.transferAnimationCue = nil
    resetMeasurements()
  }

  /// Returns `true` once the configured number of fresh, consecutive near
  /// samples has been reached. Nil, stale, out-of-range, future-dated, and
  /// widely-gapped samples reset the streak.
  @discardableResult
  public mutating func recordMeasurement(
    _ measurement: NearbyMeasurement?,
    now: Date
  ) throws -> Bool {
    try requirePhase([.ranging])
    guard let measurement, let distance = measurement.distanceMeters else {
      resetMeasurements()
      return false
    }

    let age = now.timeIntervalSince(measurement.capturedAt)
    guard age >= 0, age <= configuration.maximumSampleAge,
      distance.isFinite, distance >= 0,
      distance <= configuration.maximumDistanceMeters
    else {
      resetMeasurements()
      return false
    }

    if let lastAcceptedSampleAt {
      let gap = measurement.capturedAt.timeIntervalSince(lastAcceptedSampleAt)
      if gap <= 0 || gap > configuration.maximumGapBetweenSamples {
        resetMeasurements()
      }
    }

    consecutiveSamples += 1
    lastAcceptedSampleAt = measurement.capturedAt
    state.proximitySatisfied =
      consecutiveSamples >= configuration.requiredConsecutiveSamples
    return state.proximitySatisfied
  }

  public mutating func resetMeasurements() {
    consecutiveSamples = 0
    lastAcceptedSampleAt = nil
    state.proximitySatisfied = false
  }

  public mutating func showPreview(
    peerCard: PublicPetCardV1,
    encounterID: String? = nil
  ) throws {
    try requirePhase([.ranging])
    guard state.proximitySatisfied else {
      throw EncounterTransitionError.proximityNotSatisfied
    }
    state.peerCard = peerCard
    if let encounterID {
      state.encounterID = encounterID
    }
    state.phase = .preview
  }

  public mutating func confirmLocal(now: Date) throws {
    try confirm(local: true, now: now)
  }

  public mutating func confirmPeer(now: Date) throws {
    try confirm(local: false, now: now)
  }

  public mutating func fail(_ failure: EncounterFailure) {
    guard state.phase != .completed, state.phase != .cancelled else { return }
    state.phase = .failed
    state.failure = failure
    resetMeasurements()
  }

  public mutating func cancel() {
    guard state.phase != .completed else { return }
    state.phase = .cancelled
    state.failure = nil
    resetMeasurements()
  }

  public mutating func applyTransferAnimationCue(
    _ cue: PetTransferAnimationCue
  ) throws {
    try requirePhase([.completed])
    guard cue.eventID == state.encounterID else {
      throw EncounterTransitionError.transferAnimationIdentityMismatch
    }
    guard state.transferRole == nil || cue.role == state.transferRole else {
      throw EncounterTransitionError.transferAnimationIdentityMismatch
    }
    state.transferRole = cue.role
    state.transferAnimationCue = cue
  }

  private mutating func confirm(local: Bool, now: Date) throws {
    try requirePhase([.preview, .awaitingConfirmations, .completed])
    guard state.phase != .completed else { return }
    if local {
      state.localConfirmed = true
    } else {
      state.peerConfirmed = true
    }
    state.phase = .awaitingConfirmations

    guard state.localConfirmed, state.peerConfirmed else { return }
    guard let peerCard = state.peerCard else {
      throw EncounterTransitionError.missingPeerCard
    }
    guard let encounterID = state.encounterID else {
      throw EncounterTransitionError.missingEncounterID
    }
    let participantID = localParticipantID ?? ""
    state.encounter = Encounter(
      id: encounterID,
      localParticipantID: participantID,
      peerCard: peerCard,
      completedAt: now
    )
    state.phase = .completed
  }

  private func requirePhase(_ expected: [EncounterPhase]) throws {
    guard expected.contains(state.phase) else {
      throw EncounterTransitionError.invalidPhase(expected: expected, actual: state.phase)
    }
  }
}
