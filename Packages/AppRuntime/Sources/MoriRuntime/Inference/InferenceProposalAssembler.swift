import Foundation
import MoriDomain

public enum InferenceAssemblyError: Error, Hashable, Sendable {
  case scopeMismatch
  case sensingEpochMismatch
  case unauthorizedEvidence(EvidenceID)
  case malformedProposal
  case invalidEvent(MoriDomainRejection)
  case invalidTask(MoriDomainRejection)
}

public struct PassiveEventAssemblyIdentity: Hashable, Sendable {
  public let eventID: EventID
  public let reminderRevision: LamportRevision

  public init(eventID: EventID, reminderRevision: LamportRevision) {
    self.eventID = eventID
    self.reminderRevision = reminderRevision
  }
}

public struct TaskAssemblyIdentity: Hashable, Sendable {
  public let taskID: TaskID
  public let settlementID: TaskSettlementID
  public let issuedRevision: LamportRevision

  public init(
    taskID: TaskID,
    settlementID: TaskSettlementID,
    issuedRevision: LamportRevision
  ) {
    self.taskID = taskID
    self.settlementID = settlementID
    self.issuedRevision = issuedRevision
  }
}

/// Converts validated proposals into domain records only after the caller supplies
/// durable identities and the normalized facts referenced by the proposal.
public struct InferenceProposalAssembler: Sendable {
  public init() {}

  public func assembleEvent(
    _ proposal: PassiveEventProposal,
    identity: PassiveEventAssemblyIdentity,
    profile: RuntimeProfile,
    currentSensingEpoch: SensingEpoch,
    authorizedFacts: [DerivedFactRecord]
  ) throws -> PassiveCompanionEvent {
    guard
      proposal.profileID == profile.id,
      proposal.profileEpoch == profile.epoch,
      proposal.deletionEpoch == profile.deletionEpoch
    else {
      throw InferenceAssemblyError.scopeMismatch
    }
    guard proposal.sensingEpoch == currentSensingEpoch else {
      throw InferenceAssemblyError.sensingEpochMismatch
    }
    guard
      proposal.sourceCandidateID.isEmpty == false,
      proposal.confidence.permitsVisibleClaim,
      proposal.evidence.isEmpty == false,
      proposal.evidence.count
        <= MoriInferenceCapabilityBudgets.maximumPersistedEvidenceReferencesPerEvent
    else {
      throw InferenceAssemblyError.malformedProposal
    }

    var factsByID: [EvidenceID: DerivedFactRecord] = [:]
    for fact in authorizedFacts {
      guard factsByID.updateValue(fact, forKey: fact.header.recordID) == nil else {
        throw InferenceAssemblyError.malformedProposal
      }
    }
    for reference in proposal.evidence {
      guard
        let fact = factsByID[reference.id],
        fact.header.scopeMatches(profile),
        fact.value.kind == reference.kind,
        fact.authorizesCompanionUse(in: currentSensingEpoch),
        fact.isUsable(at: proposal.observedAt, in: profile)
      else {
        throw InferenceAssemblyError.unauthorizedEvidence(reference.id)
      }
    }

    let event = PassiveCompanionEvent(
      header: ProfileScopedRecordHeader(
        recordID: identity.eventID,
        profileID: profile.id,
        profileEpoch: profile.epoch,
        deletionEpoch: profile.deletionEpoch
      ),
      sensingEpoch: proposal.sensingEpoch,
      kind: proposal.kind,
      observedAt: proposal.observedAt,
      confidence: proposal.confidence,
      evidence: proposal.evidence,
      presentationDeadline: proposal.presentationDeadline,
      replacementKey: proposal.replacementKey,
      taskCooldownKey: proposal.taskCooldownKey,
      memoryEligibility: proposal.memoryEligibility,
      sceneID: proposal.sceneID,
      moriActionID: proposal.moriActionID,
      reminderRevision: identity.reminderRevision
    )
    if let rejection = event.validate(in: profile, sensingEpoch: currentSensingEpoch) {
      throw InferenceAssemblyError.invalidEvent(rejection)
    }
    return event
  }

  public func assembleTask(
    _ proposal: MoriTaskProposal,
    identity: TaskAssemblyIdentity,
    sourceEvent: PassiveCompanionEvent,
    profile: RuntimeProfile
  ) throws -> TaskInstance {
    guard sourceEvent.taskCooldownKey == proposal.cooldownKey else {
      throw InferenceAssemblyError.malformedProposal
    }
    let task = TaskInstance(
      header: ProfileScopedRecordHeader(
        recordID: identity.taskID,
        profileID: profile.id,
        profileEpoch: profile.epoch,
        deletionEpoch: profile.deletionEpoch
      ),
      sourceEventID: sourceEvent.header.recordID,
      kind: proposal.kind,
      cooldownKey: proposal.cooldownKey,
      recommendationPriority: proposal.recommendationPriority,
      completionPolicy: proposal.completionPolicy,
      issuedAt: proposal.issuedAt,
      issuedRevision: identity.issuedRevision,
      cooldownDuration: proposal.cooldownDuration,
      expiresAt: proposal.expiresAt,
      rewardTier: proposal.rewardTier,
      settlementID: identity.settlementID,
      lifecycleRevision: identity.issuedRevision
    )
    if let rejection = task.validate(in: profile) {
      throw InferenceAssemblyError.invalidTask(rejection)
    }
    return task
  }
}
