import Foundation
import MoriDomain
import Testing

@testable import MoriRuntime

@Suite("Mori passive inference policy")
struct PassiveInferencePipelineTests {
  private let now = Date(timeIntervalSince1970: 1_760_000_000)
  private let profile: RuntimeProfile
  private let sensingEpoch: SensingEpoch

  init() {
    let profileRevision = LamportRevision(counter: 10, originDeviceID: "iphone")
    let deletionRevision = LamportRevision(counter: 1, originDeviceID: "iphone")
    profile = RuntimeProfile(
      id: ProfileID("real"),
      epoch: ProfileEpoch(profileRevision),
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("initial"),
        revision: deletionRevision
      ),
      source: .real
    )
    sensingEpoch = SensingEpoch(LamportRevision(counter: 20, originDeviceID: "watch"))
  }

  @Test("A normal day produces an exact shared-walk claim without manufacturing a task")
  func normalDay() {
    let step = fact(
      id: "steps-3250",
      at: now.addingTimeInterval(-30),
      value: .stepTotal(3_250),
      provenance: .healthSummary
    )

    let outcome = evaluate(facts: [step])

    #expect(outcome.candidate?.kind == .sharedWalk)
    #expect(outcome.candidate?.confidence == .exact)
    #expect(outcome.candidate?.presentation.style == .natural)
    #expect(outcome.candidate?.presentation.copy == "我们已经一起走了 3,250 步。")
    #expect(outcome.eventProposal?.memoryEligibility == .eligible)
    #expect(outcome.taskProposal == nil)
    #expect(outcome.taskDecision == .notSuggested)
  }

  @Test("Corroborated fast walking is high confidence and proposes one confirmable task")
  func fastWalking() {
    let olderSteps = fact(
      id: "steps-2800",
      at: now.addingTimeInterval(-5 * 60),
      value: .stepTotal(2_800),
      provenance: .healthSummary
    )
    let newerSteps = fact(
      id: "steps-3300",
      at: now.addingTimeInterval(-60),
      value: .stepTotal(3_300),
      provenance: .healthSummary
    )
    let walking = fact(
      id: "motion-walking",
      at: now.addingTimeInterval(-60),
      value: .broadMotion(.walking),
      provenance: .motionClassifier
    )

    let outcome = evaluate(facts: [newerSteps, walking, olderSteps])

    #expect(outcome.candidate?.kind == .fastPace)
    #expect(outcome.candidate?.confidence == .high)
    #expect(outcome.candidate?.evidence.count == 3)
    #expect(outcome.candidate?.presentation.copy == "刚才那段路走得好快，我差点跟不上。")
    #expect(outcome.taskProposal?.kind == .hydrate)
    #expect(outcome.taskProposal?.completionPolicy == .userConfirmation)
    #expect(outcome.taskProposal?.rewardTier == .smallest)
    #expect(outcome.taskDecision == .proposed)
    #expect(outcome.eventProposal?.taskCooldownKey == outcome.taskProposal?.cooldownKey)
  }

  @Test("Walking followed by stopping becomes a shared pause")
  func walkAndStop() {
    let walking = fact(
      id: "motion-walking",
      at: now.addingTimeInterval(-4 * 60),
      value: .broadMotion(.walking),
      provenance: .motionClassifier
    )
    let stopped = fact(
      id: "motion-stopped",
      at: now.addingTimeInterval(-30),
      value: .broadMotion(.stationary),
      provenance: .motionClassifier
    )

    let outcome = evaluate(facts: [walking, stopped])

    #expect(outcome.candidate?.kind == .pausedTogether)
    #expect(outcome.candidate?.confidence == .high)
    #expect(outcome.candidate?.presentation.copy == "你停下来的时候，我也坐了一会儿。")
    #expect(outcome.candidate?.moriActionID == "companion.sit")
    #expect(outcome.taskProposal?.kind == .mindfulPause)
    #expect(outcome.eventProposal?.memoryEligibility == .eligible)
  }

  @Test("A late sleep reflection keeps the exact duration and recommends winding down")
  func lateSleep() {
    let sleep = fact(
      id: "sleep-last-night",
      at: now.addingTimeInterval(-15 * 60),
      value: .sleepDuration(7.5 * 60 * 60),
      provenance: .healthSummary
    )

    let outcome = evaluate(facts: [sleep], localHour: 22)

    #expect(outcome.candidate?.kind == .sleepReflection)
    #expect(outcome.candidate?.confidence == .exact)
    #expect(outcome.candidate?.presentation.copy == "昨晚，我们睡了 7 小时 30 分钟。")
    #expect(outcome.taskProposal?.kind == .bedtimeWindDown)
    #expect(outcome.taskProposal?.completionPolicy == .userConfirmation)
  }

  @Test("Denied permission is neutral even when cached input looks useful")
  func deniedPermissionNeutrality() {
    let outcome = evaluate(
      facts: [
        fact(
          id: "cached-steps",
          at: now.addingTimeInterval(-30),
          value: .stepTotal(9_999),
          provenance: .healthSummary
        )
      ],
      activationStatus: .permissionDenied
    )

    #expect(outcome == .neutral(.permissionDenied))
  }

  @Test("Stale evidence is ignored without a claim, task, or memory")
  func staleEvidenceNeutrality() {
    let stale = fact(
      id: "stale-steps",
      at: now.addingTimeInterval(-3_600),
      freshUntil: now.addingTimeInterval(-1),
      value: .stepTotal(4_000),
      provenance: .healthSummary
    )

    let outcome = evaluate(facts: [stale])

    #expect(outcome == .neutral(.noUsableEvidence))
  }

  @Test("Peer-offline inference continues while a superseded sensing epoch is rejected")
  func offlineAndSupersededEpoch() {
    let current = fact(
      id: "current-steps",
      at: now.addingTimeInterval(-30),
      value: .stepTotal(500),
      provenance: .healthSummary
    )
    #expect(
      evaluate(facts: [current], activationStatus: .peerOffline)
        .eventProposal?.kind == .sharedWalk
    )

    let oldEpoch = SensingEpoch(LamportRevision(counter: 19, originDeviceID: "watch"))
    let oldActivation = activation(status: .active, sensingEpoch: oldEpoch)
    let request = PassiveInferenceRequest(
      profile: profile,
      sensingEpoch: sensingEpoch,
      evaluatedAt: now,
      localHour: 12,
      activation: oldActivation,
      facts: [current]
    )
    #expect(
      PassiveInferencePipeline().evaluate(request)
        == .neutral(.supersededSensingEpoch)
    )
  }

  @Test("A normalized reality candidate can create only one passive event")
  func oneEventPerCandidate() throws {
    let facts = fastWalkingFacts()
    let first = evaluate(facts: facts)
    let sourceID = try #require(first.candidate?.sourceCandidateID)

    let repeated = evaluate(
      facts: facts,
      existingEventSourceCandidateIDs: [sourceID]
    )

    #expect(repeated.candidate?.sourceCandidateID == sourceID)
    #expect(repeated.eventProposal == nil)
    #expect(repeated.taskProposal == nil)
    #expect(repeated.neutralityReason == .existingCandidate)
  }

  @Test("Newest substantive evidence wins and a foreground greeting cannot hide it")
  func recencyAndSalience() {
    let oldSleep = fact(
      id: "sleep-old",
      at: now.addingTimeInterval(-8 * 3_600),
      value: .sleepDuration(7 * 3_600),
      provenance: .healthSummary
    )
    let recentSteps = fact(
      id: "steps-recent",
      at: now.addingTimeInterval(-30),
      value: .stepTotal(250),
      provenance: .healthSummary
    )
    let foreground = fact(
      id: "foreground-now",
      at: now.addingTimeInterval(-1),
      value: .foregroundInteraction,
      provenance: .foregroundInteraction
    )

    let outcome = evaluate(facts: [foreground, oldSleep, recentSteps])

    #expect(outcome.candidate?.kind == .sharedWalk)
    #expect(outcome.candidate?.presentation.copy == "我们已经一起走了 250 步。")
  }

  @Test("Approved place and foreground interaction use tentative, non-clinical copy")
  func remainingEventKinds() {
    let park = fact(
      id: "place-park",
      at: now.addingTimeInterval(-30),
      value: .approvedPlaceCategory(.park),
      provenance: .coarsePlaceClassifier
    )
    let arrival = evaluate(facts: [park])
    #expect(arrival.candidate?.kind == .arrivedAtApprovedPlace)
    #expect(arrival.candidate?.confidence == .medium)
    #expect(arrival.candidate?.presentation.style == .tentative)
    #expect(arrival.candidate?.presentation.copy == "我们好像到公园了。")
    #expect(arrival.candidate?.memoryEligibility == .ineligible)

    let interaction = fact(
      id: "foreground-open",
      at: now.addingTimeInterval(-5),
      value: .foregroundInteraction,
      provenance: .foregroundInteraction
    )
    let greeting = evaluate(facts: [interaction])
    #expect(greeting.candidate?.kind == .foregroundGreeting)
    #expect(greeting.candidate?.presentation.style == .tentative)
    #expect(
      greeting.candidate?.presentation.copy
        == "你好像回来看看我了，我刚好也醒着。"
    )
    #expect(greeting.taskProposal == nil)
  }

  @Test("Candidate identity frames arbitrary evidence identifiers")
  func candidateIdentityHasNoDelimiterCollision() {
    let first = PassiveInferencePipeline.sourceCandidateID(
      kind: .sharedWalk,
      evidence: [
        EvidenceReference(id: EvidenceID("a:b"), kind: .stepSummary),
        EvidenceReference(id: EvidenceID("c"), kind: .broadMotion),
      ]
    )
    let second = PassiveInferencePipeline.sourceCandidateID(
      kind: .sharedWalk,
      evidence: [
        EvidenceReference(id: EvidenceID("a"), kind: .stepSummary),
        EvidenceReference(id: EvidenceID("b:c"), kind: .broadMotion),
      ]
    )

    #expect(first != second)
  }

  @Test("An isolated motion hint remains silent and can never create a task")
  func lowConfidenceIsSilent() {
    let walking = fact(
      id: "motion-only",
      at: now.addingTimeInterval(-30),
      value: .broadMotion(.walking),
      provenance: .motionClassifier
    )

    let outcome = evaluate(facts: [walking])

    #expect(outcome.candidate?.kind == .sharedWalk)
    #expect(outcome.candidate?.confidence == .low)
    #expect(outcome.candidate?.presentation.style == .silent)
    #expect(outcome.candidate?.presentation.copy == nil)
    #expect(outcome.eventProposal == nil)
    #expect(outcome.taskProposal == nil)
    #expect(outcome.taskDecision == .suppressedLowConfidence)
  }

  @Test("Task source identity, cooldown, and latest-glance replacement are deterministic")
  func deduplicationAndReplacement() {
    let facts = fastWalkingFacts()
    let first = evaluate(facts: facts)
    let sourceID = try! #require(first.candidate?.sourceCandidateID)
    let taskKey = try! #require(first.taskProposal?.cooldownKey)

    let duplicate = evaluate(
      facts: facts,
      existingTaskSourceCandidateIDs: [sourceID]
    )
    #expect(duplicate.taskProposal == nil)
    #expect(duplicate.taskDecision == .suppressedExistingSource)

    let cooldownEnd = now.addingTimeInterval(3_600)
    let coolingDown = evaluate(
      facts: facts,
      cooldowns: [TaskCooldownSnapshot(key: taskKey, nextEligibleAt: cooldownEnd)]
    )
    #expect(coolingDown.taskProposal == nil)
    #expect(coolingDown.taskDecision == .suppressedCooldown(until: cooldownEnd))

    let oldEventID = EventID("old-glance")
    let replacing = evaluate(
      facts: facts,
      pending: [
        PendingPassiveGlance(
          eventID: oldEventID,
          replacementKey: "mori.passive-glance.latest",
          observedAt: now.addingTimeInterval(-10 * 60),
          presentationDeadline: now.addingTimeInterval(60)
        )
      ]
    )
    #expect(replacing.replacementDecision == .replace(oldEventID))
  }

  @Test("Assembler rechecks sensing authorization before creating domain records")
  func assemblyAuthorizationFence() throws {
    let facts = fastWalkingFacts()
    let outcome = evaluate(facts: facts)
    let proposal = try #require(outcome.eventProposal)
    let assembler = InferenceProposalAssembler()
    let event = try assembler.assembleEvent(
      proposal,
      identity: PassiveEventAssemblyIdentity(
        eventID: EventID("fast-event"),
        reminderRevision: LamportRevision(counter: 21, originDeviceID: "watch")
      ),
      profile: profile,
      currentSensingEpoch: sensingEpoch,
      authorizedFacts: facts
    )
    #expect(event.kind == .fastPace)

    let taskProposal = try #require(outcome.taskProposal)
    let task = try assembler.assembleTask(
      taskProposal,
      identity: TaskAssemblyIdentity(
        taskID: TaskID("hydrate-task"),
        settlementID: TaskSettlementID("hydrate-settlement"),
        issuedRevision: LamportRevision(counter: 22, originDeviceID: "iphone")
      ),
      sourceEvent: event,
      profile: profile
    )
    #expect(task.sourceEventID == event.header.recordID)

    let oldEpoch = SensingEpoch(LamportRevision(counter: 19, originDeviceID: "watch"))
    #expect(throws: InferenceAssemblyError.sensingEpochMismatch) {
      _ = try assembler.assembleEvent(
        proposal,
        identity: PassiveEventAssemblyIdentity(
          eventID: EventID("rejected-event"),
          reminderRevision: LamportRevision(counter: 23, originDeviceID: "watch")
        ),
        profile: profile,
        currentSensingEpoch: oldEpoch,
        authorizedFacts: facts
      )
    }
  }

  @Test("Capability budgets state the product's privacy and continuity boundaries")
  func capabilityBoundaries() {
    #expect(!MoriInferenceCapabilityBudgets.persistsRawEvidence)
    #expect(!MoriInferenceCapabilityBudgets.persistsPreciseCoordinates)
    #expect(!MoriInferenceCapabilityBudgets.guaranteesBackgroundContinuity)
    #expect(!MoriInferenceCapabilityBudgets.makesBatteryLifeGuarantee)
    #expect(MoriBackgroundDeliveryPolicy.bestEffort.rawValue == "bestEffort")
    #expect(
      MoriInferenceCapabilityBudgets.maximumPersistedEvidenceReferencesPerEvent == 4
    )
  }

  private func evaluate(
    facts: [DerivedFactRecord],
    localHour: Int = 12,
    activationStatus: CompanionActivationStatus = .active,
    pending: [PendingPassiveGlance] = [],
    cooldowns: [TaskCooldownSnapshot] = [],
    existingEventSourceCandidateIDs: Set<String> = [],
    existingTaskSourceCandidateIDs: Set<String> = []
  ) -> PassiveInferenceOutcome {
    PassiveInferencePipeline().evaluate(
      PassiveInferenceRequest(
        profile: profile,
        sensingEpoch: sensingEpoch,
        evaluatedAt: now,
        localHour: localHour,
        activation: activation(status: activationStatus),
        facts: facts,
        pendingGlances: pending,
        taskCooldowns: cooldowns,
        existingEventSourceCandidateIDs: existingEventSourceCandidateIDs,
        existingTaskSourceCandidateIDs: existingTaskSourceCandidateIDs
      )
    )
  }

  private func activation(
    status: CompanionActivationStatus,
    sensingEpoch epoch: SensingEpoch? = nil
  ) -> CompanionActivationFact {
    CompanionActivationFact(
      profileID: profile.id,
      profileEpoch: profile.epoch,
      deletionEpoch: profile.deletionEpoch,
      sensingEpoch: epoch ?? sensingEpoch,
      observedAt: now.addingTimeInterval(-60),
      freshUntil: now.addingTimeInterval(60),
      status: status
    )
  }

  private func fact(
    id: String,
    at observedAt: Date,
    freshUntil: Date? = nil,
    value: DerivedFactValue,
    provenance: EvidenceProvenance
  ) -> DerivedFactRecord {
    DerivedFactRecord(
      header: ProfileScopedRecordHeader(
        recordID: EvidenceID(id),
        profileID: profile.id,
        profileEpoch: profile.epoch,
        deletionEpoch: profile.deletionEpoch
      ),
      observedAt: observedAt,
      freshUntil: freshUntil ?? now.addingTimeInterval(5 * 60),
      value: value,
      provenance: provenance,
      authorization: .companion(sensingEpoch)
    )
  }

  private func fastWalkingFacts() -> [DerivedFactRecord] {
    [
      fact(
        id: "steps-2800",
        at: now.addingTimeInterval(-5 * 60),
        value: .stepTotal(2_800),
        provenance: .healthSummary
      ),
      fact(
        id: "steps-3300",
        at: now.addingTimeInterval(-60),
        value: .stepTotal(3_300),
        provenance: .healthSummary
      ),
      fact(
        id: "motion-walking",
        at: now.addingTimeInterval(-60),
        value: .broadMotion(.walking),
        provenance: .motionClassifier
      ),
    ]
  }
}
