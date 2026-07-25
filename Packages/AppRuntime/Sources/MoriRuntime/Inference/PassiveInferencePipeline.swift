import CryptoKit
import Foundation
import MoriDomain

/// A deterministic, on-device policy over normalized facts. The pipeline is pure:
/// it performs no I/O, creates no persisted records, and has no hidden clock.
public struct PassiveInferencePipeline: Sendable {
  private static let replacementKey = "mori.passive-glance.latest"

  public init() {}

  public static func sourceCandidateID(for event: PassiveCompanionEvent) -> String {
    sourceCandidateID(kind: event.kind, evidence: event.evidence)
  }

  public func evaluate(_ request: PassiveInferenceRequest) -> PassiveInferenceOutcome {
    guard (0...23).contains(request.localHour) else {
      return .neutral(.invalidLocalTime)
    }
    guard request.activation.sensingEpoch == request.sensingEpoch else {
      return .neutral(.supersededSensingEpoch)
    }
    guard request.activation.observedAt <= request.evaluatedAt,
      request.activation.freshUntil >= request.evaluatedAt
    else {
      return .neutral(.staleActivation)
    }
    switch request.activation.status {
    case .active:
      guard
        request.activation.authorizes(
          profile: request.profile,
          sensingEpoch: request.sensingEpoch,
          at: request.evaluatedAt
        )
      else {
        return .neutral(.supersededSensingEpoch)
      }
    case .disabled:
      return .neutral(.inactive)
    case .permissionDenied:
      return .neutral(.permissionDenied)
    case .unavailable:
      return .neutral(.unavailable)
    case .peerOffline:
      guard
        request.activation.authorizes(
          profile: request.profile,
          sensingEpoch: request.sensingEpoch,
          at: request.evaluatedAt
        )
      else {
        return .neutral(.supersededSensingEpoch)
      }
    }

    let facts = usableFacts(for: request)
    guard facts.isEmpty == false else {
      return .neutral(.noUsableEvidence)
    }
    guard let candidate = candidate(from: facts, request: request) else {
      return .neutral(.noCandidate)
    }
    guard candidate.confidence.permitsVisibleClaim else {
      return PassiveInferenceOutcome(
        candidate: candidate,
        eventProposal: nil,
        taskProposal: nil,
        replacementDecision: .none,
        taskDecision: .suppressedLowConfidence,
        neutralityReason: .lowConfidence
      )
    }
    guard
      request.existingEventSourceCandidateIDs.contains(candidate.sourceCandidateID) == false
    else {
      return PassiveInferenceOutcome(
        candidate: candidate,
        eventProposal: nil,
        taskProposal: nil,
        replacementDecision: .none,
        taskDecision: .notSuggested,
        neutralityReason: .existingCandidate
      )
    }

    let replacement = replacementDecision(for: candidate, request: request)
    if case .suppressBecauseNewerEventExists = replacement {
      return PassiveInferenceOutcome(
        candidate: candidate,
        eventProposal: nil,
        taskProposal: nil,
        replacementDecision: replacement,
        taskDecision: .notSuggested,
        neutralityReason: .newerPendingEvent
      )
    }

    let baseTask = taskProposal(for: candidate, request: request)
    let taskResult = decideTask(baseTask, candidate: candidate, request: request)
    let eventProposal = PassiveEventProposal(
      profileID: request.profile.id,
      profileEpoch: request.profile.epoch,
      deletionEpoch: request.profile.deletionEpoch,
      sensingEpoch: request.sensingEpoch,
      sourceCandidateID: candidate.sourceCandidateID,
      kind: candidate.kind,
      observedAt: candidate.observedAt,
      confidence: candidate.confidence,
      evidence: candidate.evidence,
      presentationDeadline: request.evaluatedAt.addingTimeInterval(
        MoriInferenceCapabilityBudgets.glancePresentationLifetime
      ),
      replacementKey: Self.replacementKey,
      taskCooldownKey: taskResult.proposal?.cooldownKey,
      memoryEligibility: candidate.memoryEligibility,
      sceneID: candidate.sceneID,
      moriActionID: candidate.moriActionID,
      presentation: candidate.presentation
    )
    return PassiveInferenceOutcome(
      candidate: candidate,
      eventProposal: eventProposal,
      taskProposal: taskResult.proposal,
      replacementDecision: replacement,
      taskDecision: taskResult.decision,
      neutralityReason: nil
    )
  }

  private func usableFacts(for request: PassiveInferenceRequest) -> [DerivedFactRecord] {
    request.facts
      .filter {
        $0.isUsable(at: request.evaluatedAt, in: request.profile)
          && $0.authorizesCompanionUse(in: request.sensingEpoch)
      }
      .sorted {
        if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
        return $0.header.recordID < $1.header.recordID
      }
      .prefix(MoriInferenceCapabilityBudgets.maximumNormalizedFactsPerEvaluation)
      .map { $0 }
  }

  private func candidate(
    from facts: [DerivedFactRecord],
    request: PassiveInferenceRequest
  ) -> BoundedInferenceCandidate? {
    let motions = facts.compactMap { fact -> (DerivedFactRecord, BroadMotion)? in
      guard case .broadMotion(let motion) = fact.value else { return nil }
      return (fact, motion)
    }
    let steps = facts.compactMap { fact -> (DerivedFactRecord, Int)? in
      guard case .stepTotal(let value) = fact.value else { return nil }
      return (fact, value)
    }

    var substantive: [(candidate: BoundedInferenceCandidate, priority: Int)] = []
    if let result = pausedCandidate(motions: motions) {
      substantive.append((result, 5))
    }
    if let result = fastPaceCandidate(steps: steps, motions: motions) {
      substantive.append((result, 6))
    }
    if let fact = facts.first(where: {
      if case .sleepDuration = $0.value { return true }
      return false
    }) {
      substantive.append((sleepCandidate(fact), 1))
    }
    if let fact = facts.first(where: {
      if case .approvedPlaceCategory = $0.value { return true }
      return false
    }) {
      substantive.append((placeCandidate(fact), 4))
    }
    if let latestStep = steps.first, latestStep.1 > 0 {
      substantive.append((sharedWalkCandidate(latestStep), 2))
    }
    if let selected = substantive.max(by: {
      if $0.candidate.observedAt != $1.candidate.observedAt {
        return $0.candidate.observedAt < $1.candidate.observedAt
      }
      if $0.priority != $1.priority { return $0.priority < $1.priority }
      return $0.candidate.sourceCandidateID < $1.candidate.sourceCandidateID
    }) {
      return selected.candidate
    }
    if let fact = facts.first(where: {
      if case .foregroundInteraction = $0.value { return true }
      return false
    }) {
      return foregroundCandidate(fact)
    }
    if let motion = motions.first, motion.1 == .walking || motion.1 == .running {
      return makeCandidate(
        kind: .sharedWalk,
        facts: [motion.0],
        confidence: .low,
        copy: nil,
        sceneID: nil,
        actionID: "observe.walking"
      )
    }
    return nil
  }

  private func pausedCandidate(
    motions: [(DerivedFactRecord, BroadMotion)]
  ) -> BoundedInferenceCandidate? {
    guard
      let stopped = motions.first(where: { $0.1 == .stationary }),
      let moving = motions.first(where: {
        ($0.1 == .walking || $0.1 == .running)
          && $0.0.observedAt < stopped.0.observedAt
          && stopped.0.observedAt.timeIntervalSince($0.0.observedAt) <= 10 * 60
      })
    else { return nil }
    return makeCandidate(
      kind: .pausedTogether,
      facts: [moving.0, stopped.0],
      confidence: .high,
      copy: "你停下来的时候，我也坐了一会儿。",
      sceneID: "path.pause",
      actionID: "companion.sit"
    )
  }

  private func fastPaceCandidate(
    steps: [(DerivedFactRecord, Int)],
    motions: [(DerivedFactRecord, BroadMotion)]
  ) -> BoundedInferenceCandidate? {
    guard steps.count >= 2 else { return nil }
    let newest = steps[0]
    guard
      let older = steps.dropFirst().first(where: {
        let interval = newest.0.observedAt.timeIntervalSince($0.0.observedAt)
        return interval >= 60 && interval <= 20 * 60 && newest.1 > $0.1
      })
    else { return nil }
    let minutes = newest.0.observedAt.timeIntervalSince(older.0.observedAt) / 60
    let cadence = Double(newest.1 - older.1) / minutes
    guard cadence >= 100 else { return nil }
    guard
      let motion = motions.first(where: {
        ($0.1 == .walking || $0.1 == .running)
          && abs($0.0.observedAt.timeIntervalSince(newest.0.observedAt)) <= 5 * 60
      })
    else { return nil }
    return makeCandidate(
      kind: .fastPace,
      facts: [older.0, newest.0, motion.0],
      confidence: .high,
      copy: "刚才那段路走得好快，我差点跟不上。",
      sceneID: "path.fast",
      actionID: "companion.catch-up"
    )
  }

  private func sleepCandidate(_ fact: DerivedFactRecord) -> BoundedInferenceCandidate {
    guard case .sleepDuration(let duration) = fact.value else {
      preconditionFailure("sleepCandidate requires a sleep fact")
    }
    return makeCandidate(
      kind: .sleepReflection,
      facts: [fact],
      confidence: .exact,
      copy: "昨晚，我们睡了 \(durationText(duration))。",
      sceneID: "home.sleep-reflection",
      actionID: "companion.sleep-reflection"
    )
  }

  private func placeCandidate(_ fact: DerivedFactRecord) -> BoundedInferenceCandidate {
    guard case .approvedPlaceCategory(let category) = fact.value else {
      preconditionFailure("placeCandidate requires a place fact")
    }
    let copy =
      switch category {
      case .home: "我们好像到家了。"
      case .work: "我们好像到了熟悉的工作地点。"
      case .park: "我们好像到公园了。"
      case .transit: "我们好像到了常去的车站。"
      case .other: "我们好像到了一个熟悉的地方。"
      }
    return makeCandidate(
      kind: .arrivedAtApprovedPlace,
      facts: [fact],
      confidence: .medium,
      copy: copy,
      sceneID: "place.\(category.rawValue)",
      actionID: "companion.look-around"
    )
  }

  private func sharedWalkCandidate(
    _ step: (DerivedFactRecord, Int)
  ) -> BoundedInferenceCandidate {
    makeCandidate(
      kind: .sharedWalk,
      facts: [step.0],
      confidence: .exact,
      copy: "我们已经一起走了 \(groupedDecimal(step.1)) 步。",
      sceneID: "path.day",
      actionID: "companion.walk"
    )
  }

  private func foregroundCandidate(_ fact: DerivedFactRecord) -> BoundedInferenceCandidate {
    makeCandidate(
      kind: .foregroundGreeting,
      facts: [fact],
      confidence: .medium,
      copy: "你好像回来看看我了，我刚好也醒着。",
      sceneID: nil,
      actionID: "companion.greet"
    )
  }

  private func makeCandidate(
    kind: PassiveEventKind,
    facts: [DerivedFactRecord],
    confidence: ConfidenceBand,
    copy: String?,
    sceneID: String?,
    actionID: String
  ) -> BoundedInferenceCandidate {
    let orderedFacts = facts.sorted {
      if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
      return $0.header.recordID < $1.header.recordID
    }
    let references = orderedFacts.map {
      EvidenceReference(id: $0.header.recordID, kind: $0.value.kind)
    }
    let sourceID = Self.sourceCandidateID(kind: kind, evidence: references)
    let style: MoriClaimStyle =
      switch confidence {
      case .exact, .high: .natural
      case .medium: .tentative
      case .low: .silent
      }
    return BoundedInferenceCandidate(
      sourceCandidateID: sourceID,
      kind: kind,
      observedAt: orderedFacts.map(\.observedAt).max() ?? .distantPast,
      confidence: confidence,
      evidence: references,
      presentation: MoriEventPresentation(style: style, copy: style == .silent ? nil : copy),
      memoryEligibility: confidence >= .high ? .eligible : .ineligible,
      sceneID: sceneID,
      moriActionID: actionID
    )
  }

  static func sourceCandidateID(
    kind: PassiveEventKind,
    evidence: [EvidenceReference]
  ) -> String {
    let components =
      ["mori-source-candidate-v2", kind.rawValue]
      + evidence.flatMap { [$0.kind.rawValue, $0.id.rawValue] }
    let digest = SHA256.hash(data: CanonicalHashInput.data(components))
      .map { String(format: "%02x", $0) }
      .joined()
    return "candidate-\(digest)"
  }

  private func replacementDecision(
    for candidate: BoundedInferenceCandidate,
    request: PassiveInferenceRequest
  ) -> PassiveReplacementDecision {
    guard
      let pending =
        (request.pendingGlances
          .filter {
            $0.replacementKey == Self.replacementKey && $0.isPending(at: request.evaluatedAt)
          }
          .max(by: {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            return $0.eventID < $1.eventID
          }))
    else { return .none }
    if pending.observedAt > candidate.observedAt {
      return .suppressBecauseNewerEventExists(pending.eventID)
    }
    return .replace(pending.eventID)
  }

  private func taskProposal(
    for candidate: BoundedInferenceCandidate,
    request: PassiveInferenceRequest
  ) -> MoriTaskProposal? {
    guard candidate.confidence != .low else { return nil }
    let specification:
      (
        MoriTaskKind, String, RecommendationPriority, TimeInterval, TimeInterval?,
        CoinRewardTier
      )? =
        switch candidate.kind {
        case .fastPace:
          (
            .hydrate, "task.hydrate.after-fast-pace", .recommended, 6 * 60 * 60, 2 * 60 * 60,
            .smallest
          )
        case .pausedTogether:
          (
            .mindfulPause, "task.mindful-pause.after-stop", .recommended, 12 * 60 * 60,
            2 * 60 * 60, .smallest
          )
        case .arrivedAtApprovedPlace:
          (
            .exploreNearby, "task.explore.approved-place", .normal, 24 * 60 * 60,
            4 * 60 * 60, .standard
          )
        case .sleepReflection where request.localHour >= 21:
          (
            .bedtimeWindDown, "task.bedtime-wind-down", .recommended, 24 * 60 * 60,
            3 * 60 * 60, .standard
          )
        case .sharedWalk, .sleepReflection, .foregroundGreeting:
          nil
        }
    guard let specification else { return nil }
    return MoriTaskProposal(
      sourceCandidateID: candidate.sourceCandidateID,
      kind: specification.0,
      cooldownKey: TaskCooldownKey(specification.1),
      recommendationPriority: specification.2,
      completionPolicy: .userConfirmation,
      issuedAt: request.evaluatedAt,
      cooldownDuration: specification.3,
      expiresAt: specification.4.map(request.evaluatedAt.addingTimeInterval),
      rewardTier: specification.5
    )
  }

  private func decideTask(
    _ proposal: MoriTaskProposal?,
    candidate: BoundedInferenceCandidate,
    request: PassiveInferenceRequest
  ) -> (proposal: MoriTaskProposal?, decision: TaskProposalDecision) {
    guard candidate.confidence != .low else {
      return (nil, .suppressedLowConfidence)
    }
    guard let proposal else { return (nil, .notSuggested) }
    guard request.existingTaskSourceCandidateIDs.contains(candidate.sourceCandidateID) == false
    else {
      return (nil, .suppressedExistingSource)
    }
    guard request.manualTaskSlotAvailable else {
      return (nil, .suppressedNoVisibleSlot)
    }
    if let cooldown = request.taskCooldowns
      .filter({ $0.key == proposal.cooldownKey && request.evaluatedAt < $0.nextEligibleAt })
      .max(by: { $0.nextEligibleAt < $1.nextEligibleAt })
    {
      return (nil, .suppressedCooldown(until: cooldown.nextEligibleAt))
    }
    return (proposal, .proposed)
  }

  private func groupedDecimal(_ value: Int) -> String {
    let digits = String(max(0, value))
    var result = ""
    for (offset, character) in digits.reversed().enumerated() {
      if offset > 0 && offset.isMultiple(of: 3) {
        result.append(",")
      }
      result.append(character)
    }
    return String(result.reversed())
  }

  private func durationText(_ duration: TimeInterval) -> String {
    let totalMinutes = max(0, Int((duration / 60).rounded()))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 { return "\(minutes) 分钟" }
    if minutes == 0 { return "\(hours) 小时" }
    return "\(hours) 小时 \(minutes) 分钟"
  }
}
