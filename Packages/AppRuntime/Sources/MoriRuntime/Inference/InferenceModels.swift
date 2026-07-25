import Foundation
import MoriDomain

public enum CompanionActivationStatus: Hashable, Sendable {
  case active
  case disabled
  case permissionDenied
  case unavailable
  /// The peer or sync transport is offline. Local, authorized inference keeps
  /// working and the resulting event can enter the durable outbox later.
  case peerOffline
}

/// Activation is an input fact, rather than an ambient singleton flag. This makes
/// permission denial, offline operation, and epoch changes deterministic.
public struct CompanionActivationFact: Hashable, Sendable {
  public let profileID: ProfileID
  public let profileEpoch: ProfileEpoch
  public let deletionEpoch: DeletionEpoch
  public let sensingEpoch: SensingEpoch
  public let observedAt: Date
  public let freshUntil: Date
  public let status: CompanionActivationStatus

  public init(
    profileID: ProfileID,
    profileEpoch: ProfileEpoch,
    deletionEpoch: DeletionEpoch,
    sensingEpoch: SensingEpoch,
    observedAt: Date,
    freshUntil: Date,
    status: CompanionActivationStatus
  ) {
    self.profileID = profileID
    self.profileEpoch = profileEpoch
    self.deletionEpoch = deletionEpoch
    self.sensingEpoch = sensingEpoch
    self.observedAt = observedAt
    self.freshUntil = freshUntil
    self.status = status
  }

  public func authorizes(
    profile: RuntimeProfile,
    sensingEpoch currentSensingEpoch: SensingEpoch,
    at date: Date
  ) -> Bool {
    (status == .active || status == .peerOffline)
      && profileID == profile.id
      && profileEpoch == profile.epoch
      && deletionEpoch == profile.deletionEpoch
      && sensingEpoch == currentSensingEpoch
      && date >= observedAt
      && date <= freshUntil
  }
}

public struct PendingPassiveGlance: Hashable, Sendable {
  public let eventID: EventID
  public let replacementKey: String
  public let observedAt: Date
  public let presentationDeadline: Date?

  public init(
    eventID: EventID,
    replacementKey: String,
    observedAt: Date,
    presentationDeadline: Date?
  ) {
    self.eventID = eventID
    self.replacementKey = replacementKey
    self.observedAt = observedAt
    self.presentationDeadline = presentationDeadline
  }

  public func isPending(at date: Date) -> Bool {
    presentationDeadline.map { date <= $0 } ?? true
  }
}

public struct TaskCooldownSnapshot: Hashable, Sendable {
  public let key: TaskCooldownKey
  public let nextEligibleAt: Date

  public init(key: TaskCooldownKey, nextEligibleAt: Date) {
    self.key = key
    self.nextEligibleAt = nextEligibleAt
  }
}

public struct PassiveInferenceRequest: Hashable, Sendable {
  public let profile: RuntimeProfile
  public let sensingEpoch: SensingEpoch
  public let evaluatedAt: Date
  public let localHour: Int
  public let activation: CompanionActivationFact
  public let facts: [DerivedFactRecord]
  public let pendingGlances: [PendingPassiveGlance]
  public let taskCooldowns: [TaskCooldownSnapshot]
  public let existingEventSourceCandidateIDs: Set<String>
  public let existingTaskSourceCandidateIDs: Set<String>
  public let manualTaskSlotAvailable: Bool

  public init(
    profile: RuntimeProfile,
    sensingEpoch: SensingEpoch,
    evaluatedAt: Date,
    localHour: Int,
    activation: CompanionActivationFact,
    facts: [DerivedFactRecord],
    pendingGlances: [PendingPassiveGlance] = [],
    taskCooldowns: [TaskCooldownSnapshot] = [],
    existingEventSourceCandidateIDs: Set<String> = [],
    existingTaskSourceCandidateIDs: Set<String> = [],
    manualTaskSlotAvailable: Bool = true
  ) {
    self.profile = profile
    self.sensingEpoch = sensingEpoch
    self.evaluatedAt = evaluatedAt
    self.localHour = localHour
    self.activation = activation
    self.facts = facts
    self.pendingGlances = pendingGlances
    self.taskCooldowns = taskCooldowns
    self.existingEventSourceCandidateIDs = existingEventSourceCandidateIDs
    self.existingTaskSourceCandidateIDs = existingTaskSourceCandidateIDs
    self.manualTaskSlotAvailable = manualTaskSlotAvailable
  }
}

public enum MoriClaimStyle: String, Hashable, Sendable {
  /// Used for exact summaries and strongly corroborated inferences.
  case natural
  /// Uses words such as "好像" when the signal supports only a modest inference.
  case tentative
  /// No user-facing copy is emitted.
  case silent
}

public struct MoriEventPresentation: Hashable, Sendable {
  public let style: MoriClaimStyle
  public let copy: String?

  public init(style: MoriClaimStyle, copy: String?) {
    self.style = style
    self.copy = copy
  }
}

public struct BoundedInferenceCandidate: Hashable, Sendable {
  public let sourceCandidateID: String
  public let kind: PassiveEventKind
  public let observedAt: Date
  public let confidence: ConfidenceBand
  public let evidence: [EvidenceReference]
  public let presentation: MoriEventPresentation
  public let memoryEligibility: MemoryEligibility
  public let sceneID: String?
  public let moriActionID: String

  public init(
    sourceCandidateID: String,
    kind: PassiveEventKind,
    observedAt: Date,
    confidence: ConfidenceBand,
    evidence: [EvidenceReference],
    presentation: MoriEventPresentation,
    memoryEligibility: MemoryEligibility,
    sceneID: String?,
    moriActionID: String
  ) {
    self.sourceCandidateID = sourceCandidateID
    self.kind = kind
    self.observedAt = observedAt
    self.confidence = confidence
    self.evidence = Array(
      evidence.prefix(MoriInferenceCapabilityBudgets.maximumPersistedEvidenceReferencesPerEvent)
    )
    self.presentation = presentation
    self.memoryEligibility = memoryEligibility
    self.sceneID = sceneID
    self.moriActionID = moriActionID
  }
}

public struct PassiveEventProposal: Hashable, Sendable {
  public let profileID: ProfileID
  public let profileEpoch: ProfileEpoch
  public let deletionEpoch: DeletionEpoch
  public let sensingEpoch: SensingEpoch
  public let sourceCandidateID: String
  public let kind: PassiveEventKind
  public let observedAt: Date
  public let confidence: ConfidenceBand
  public let evidence: [EvidenceReference]
  public let presentationDeadline: Date
  public let replacementKey: String
  public let taskCooldownKey: TaskCooldownKey?
  public let memoryEligibility: MemoryEligibility
  public let sceneID: String?
  public let moriActionID: String
  public let presentation: MoriEventPresentation
}

public struct MoriTaskProposal: Hashable, Sendable {
  public let sourceCandidateID: String
  public let kind: MoriTaskKind
  public let cooldownKey: TaskCooldownKey
  public let recommendationPriority: RecommendationPriority
  public let completionPolicy: TaskCompletionPolicy
  public let issuedAt: Date
  public let cooldownDuration: TimeInterval
  public let expiresAt: Date?
  public let rewardTier: CoinRewardTier
}

public enum PassiveReplacementDecision: Hashable, Sendable {
  case none
  case replace(EventID)
  case suppressBecauseNewerEventExists(EventID)
}

public enum TaskProposalDecision: Hashable, Sendable {
  case notSuggested
  case proposed
  case suppressedLowConfidence
  case suppressedCooldown(until: Date)
  case suppressedExistingSource
  case suppressedNoVisibleSlot
}

public enum InferenceNeutralityReason: Hashable, Sendable {
  case inactive
  case permissionDenied
  case unavailable
  case staleActivation
  case supersededSensingEpoch
  case invalidLocalTime
  case noUsableEvidence
  case noCandidate
  case lowConfidence
  case newerPendingEvent
  case existingCandidate
}

public struct PassiveInferenceOutcome: Hashable, Sendable {
  public let candidate: BoundedInferenceCandidate?
  public let eventProposal: PassiveEventProposal?
  public let taskProposal: MoriTaskProposal?
  public let replacementDecision: PassiveReplacementDecision
  public let taskDecision: TaskProposalDecision
  public let neutralityReason: InferenceNeutralityReason?

  public init(
    candidate: BoundedInferenceCandidate?,
    eventProposal: PassiveEventProposal?,
    taskProposal: MoriTaskProposal?,
    replacementDecision: PassiveReplacementDecision,
    taskDecision: TaskProposalDecision,
    neutralityReason: InferenceNeutralityReason?
  ) {
    self.candidate = candidate
    self.eventProposal = eventProposal
    self.taskProposal = taskProposal
    self.replacementDecision = replacementDecision
    self.taskDecision = taskDecision
    self.neutralityReason = neutralityReason
  }

  public static func neutral(_ reason: InferenceNeutralityReason) -> Self {
    Self(
      candidate: nil,
      eventProposal: nil,
      taskProposal: nil,
      replacementDecision: .none,
      taskDecision: .notSuggested,
      neutralityReason: reason
    )
  }
}
