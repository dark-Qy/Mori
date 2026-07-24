import Foundation
import Testing

@testable import MoriDomain

@Suite("Task issuance and settlement policy")
struct TaskPolicyTests {
  @Test("One reality event can issue exactly one task")
  func oneTaskPerEvent() {
    let profile = MoriTestFixtures.profile()
    var state = preparedState(profile: profile)
    let event = try! #require(state.passiveEvents.first)
    let task = MoriTestFixtures.task(event: event, profile: profile)

    #expect(
      ProfileReducer.apply(.task(task, manualTaskHasVisibleSlot: true), to: &state) == .applied)
    #expect(
      ProfileReducer.apply(.task(task, manualTaskHasVisibleSlot: true), to: &state) == .duplicate
    )

    let conflicting = MoriTestFixtures.task(
      "different-task",
      event: event,
      profile: profile,
      issuedRevision: MoriTestFixtures.revision(51)
    )
    #expect(
      ProfileReducer.apply(.task(conflicting, manualTaskHasVisibleSlot: true), to: &state)
        == .rejected(.conflictingDuplicate)
    )
    #expect(state.tasks.count == 1)
  }

  @Test("Same task type is blocked until the inclusive cooldown boundary")
  func cooldownBoundaryAndRollback() throws {
    let profile = MoriTestFixtures.profile()
    var state = preparedState(profile: profile)
    let firstEvent = try #require(state.passiveEvents.first)
    let first = MoriTestFixtures.task(
      "first",
      event: firstEvent,
      profile: profile,
      issuedAt: MoriTestFixtures.now,
      cooldownDuration: 900
    )
    #expect(
      ProfileReducer.apply(.task(first, manualTaskHasVisibleSlot: true), to: &state) == .applied)

    let secondFact = MoriTestFixtures.fact("steps-2", profile: profile)
    let secondEvent = MoriTestFixtures.event(
      "walk-2",
      profile: profile,
      sensingEpoch: state.currentSensingEpoch,
      fact: secondFact,
      observedAt: MoriTestFixtures.now.addingTimeInterval(1)
    )
    #expect(ProfileReducer.apply(.derivedFact(secondFact), to: &state) == .applied)
    #expect(ProfileReducer.apply(.passiveEvent(secondEvent), to: &state) == .applied)

    let beforeBoundary = MoriTestFixtures.task(
      "before-boundary",
      event: secondEvent,
      profile: profile,
      issuedAt: MoriTestFixtures.now.addingTimeInterval(899),
      issuedRevision: MoriTestFixtures.revision(52)
    )
    #expect(
      ProfileReducer.apply(.task(beforeBoundary, manualTaskHasVisibleSlot: true), to: &state)
        == .rejected(.cooldownActive)
    )

    // A wall-clock rollback cannot shorten a logical cooldown.
    let rolledBack = MoriTestFixtures.task(
      "rolled-back",
      event: secondEvent,
      profile: profile,
      issuedAt: MoriTestFixtures.now.addingTimeInterval(-3_600),
      issuedRevision: MoriTestFixtures.revision(53)
    )
    #expect(
      ProfileReducer.apply(.task(rolledBack, manualTaskHasVisibleSlot: true), to: &state)
        == .rejected(.cooldownActive)
    )

    let atBoundary = MoriTestFixtures.task(
      "at-boundary",
      event: secondEvent,
      profile: profile,
      issuedAt: MoriTestFixtures.now.addingTimeInterval(900),
      issuedRevision: MoriTestFixtures.revision(54)
    )
    #expect(
      ProfileReducer.apply(.task(atBoundary, manualTaskHasVisibleSlot: true), to: &state)
        == .applied
    )
  }

  @Test("Automatic completion needs high confidence; manual tasks need a visible slot")
  func completionPolicyBoundaries() {
    let profile = MoriTestFixtures.profile()
    let sensingEpoch = SensingEpoch(MoriTestFixtures.revision(30, device: "watch"))
    let mediumEvent = MoriTestFixtures.event(
      "medium",
      profile: profile,
      sensingEpoch: sensingEpoch,
      confidence: .medium
    )
    let automatic = MoriTestFixtures.task(
      "automatic",
      event: mediumEvent,
      profile: profile,
      policy: .automatic
    )
    #expect(
      TaskIssuancePolicy.evaluate(
        event: mediumEvent,
        candidate: automatic,
        existingTaskForSourceEvent: nil,
        cooldown: nil,
        manualTaskHasVisibleSlot: true,
        profile: profile,
        sensingEpoch: sensingEpoch
      ) == .rejected(.completionNotAllowed)
    )

    let manual = MoriTestFixtures.task(
      "manual",
      event: mediumEvent,
      profile: profile,
      policy: .userConfirmation
    )
    #expect(
      TaskIssuancePolicy.evaluate(
        event: mediumEvent,
        candidate: manual,
        existingTaskForSourceEvent: nil,
        cooldown: nil,
        manualTaskHasVisibleSlot: false,
        profile: profile,
        sensingEpoch: sensingEpoch
      ) == .rejected(.invisibleManualTask)
    )
    #expect(
      TaskIssuancePolicy.evaluate(
        event: mediumEvent,
        candidate: manual,
        existingTaskForSourceEvent: nil,
        cooldown: nil,
        manualTaskHasVisibleSlot: true,
        profile: profile,
        sensingEpoch: sensingEpoch
      ) == .applied
    )
  }

  @Test("Auto/manual race cannot settle a task or reward twice")
  func completionRaceAndRewardIdempotency() throws {
    let profile = MoriTestFixtures.profile()
    var state = preparedState(profile: profile)
    let event = try #require(state.passiveEvents.first)
    let task = MoriTestFixtures.task(event: event, profile: profile, reward: .meaningful)
    #expect(
      ProfileReducer.apply(.task(task, manualTaskHasVisibleSlot: true), to: &state) == .applied)

    let manual = MoriTestFixtures.taskTransition(
      "manual-racer",
      task: task,
      profile: profile,
      revision: MoriTestFixtures.revision(61, device: "iphone"),
      method: .userConfirmed
    )
    let automatic = MoriTestFixtures.taskTransition(
      "automatic-racer",
      task: task,
      profile: profile,
      revision: MoriTestFixtures.revision(60, device: "watch"),
      method: .automatic
    )

    #expect(ProfileReducer.apply(.taskTransition(manual), to: &state) == .applied)
    #expect(ProfileReducer.apply(.taskTransition(automatic), to: &state) == .applied)
    #expect(ProfileReducer.apply(.taskTransition(automatic), to: &state) == .duplicate)
    #expect(ProfileReducer.apply(.taskTransition(manual), to: &state) == .duplicate)
    guard case .completed(let method, _) = state.tasks.first?.lifecycle else {
      Issue.record("the task must remain completed")
      return
    }
    #expect(method == .automatic)

    let reward = MoriTestFixtures.reward(
      "reward",
      settlementID: task.settlementID,
      profile: profile,
      revision: MoriTestFixtures.revision(62),
      tier: .meaningful
    )
    let sameSettlement = MoriTestFixtures.reward(
      "reward-from-other-device",
      settlementID: task.settlementID,
      profile: profile,
      revision: MoriTestFixtures.revision(63, device: "watch"),
      tier: .meaningful
    )
    #expect(ProfileReducer.apply(.coinTransaction(reward), to: &state) == .applied)
    #expect(ProfileReducer.apply(.coinTransaction(reward), to: &state) == .duplicate)
    #expect(ProfileReducer.apply(.coinTransaction(sameSettlement), to: &state) == .duplicate)
    #expect(state.coinLedger.balance == CoinRewardTier.meaningful.rawValue)
  }

  @Test("Task transitions respect issuance causality and consume a genuinely late loser")
  func causalTransitionAndLateLoser() {
    let profile = MoriTestFixtures.profile("task-causality")
    let event = MoriTestFixtures.event(profile: profile)
    let task = MoriTestFixtures.task(
      event: event,
      profile: profile,
      issuedRevision: MoriTestFixtures.revision(50)
    )
    let earlierCompletion = TaskTransition(
      header: MoriTestFixtures.header(
        TaskTransitionID("earlier-completion"),
        profile: profile
      ),
      taskID: task.header.recordID,
      revision: MoriTestFixtures.revision(2),
      state: .completed(
        method: .automatic,
        at: MoriTestFixtures.now.addingTimeInterval(300)
      ),
      settlementID: task.settlementID
    )
    var active = task
    #expect(active.apply(earlierCompletion, in: profile) == .rejected(.invalidRecord))
    #expect(active.validate(in: profile) == nil)

    let expiryDate = task.expiresAt ?? MoriTestFixtures.now
    let expiry = TaskTransition(
      header: MoriTestFixtures.header(
        TaskTransitionID("expiry"),
        profile: profile
      ),
      taskID: task.header.recordID,
      revision: MoriTestFixtures.revision(51),
      state: .expired(at: expiryDate),
      settlementID: nil
    )
    let lateCompletion = TaskTransition(
      header: MoriTestFixtures.header(
        TaskTransitionID("late-completion"),
        profile: profile
      ),
      taskID: task.header.recordID,
      revision: MoriTestFixtures.revision(52),
      state: .completed(
        method: .automatic,
        at: expiryDate.addingTimeInterval(1)
      ),
      settlementID: task.settlementID
    )
    var expired = task
    #expect(expired.apply(expiry, in: profile) == .applied)
    #expect(expired.apply(lateCompletion, in: profile) == .duplicate)
    #expect(expired.lifecycle == expiry.state)
    #expect(expired.validate(in: profile) == nil)
  }

  private func preparedState(profile: RuntimeProfile) -> ProfileState {
    var state = MoriTestFixtures.state(profile: profile)
    let fact = MoriTestFixtures.fact(profile: profile)
    let event = MoriTestFixtures.event(
      profile: profile,
      sensingEpoch: state.currentSensingEpoch,
      fact: fact
    )
    _ = ProfileReducer.apply(.derivedFact(fact), to: &state)
    _ = ProfileReducer.apply(.passiveEvent(event), to: &state)
    return state
  }
}
