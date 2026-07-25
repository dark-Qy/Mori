import Foundation
import MoriDomain
import Testing

@testable import MoriRuntime

@Suite("Deterministic daily memory")
struct DailyMemoryRuntimeTests {
  private let releaseDate = ExperienceTestFixtures.date("2026-07-24T14:00:00Z")

  @Test("iPhone seals after 22:00 while Watch only waits for the synced record")
  func authorityAndReleaseTime() async throws {
    let fact = ExperienceTestFixtures.fact(
      "steps",
      observedAt: releaseDate.addingTimeInterval(-3_600)
    )
    let event = ExperienceTestFixtures.event(
      "walk",
      observedAt: fact.observedAt,
      fact: fact
    )
    let state = ExperienceTestFixtures.state(
      facts: [fact],
      events: [event]
    )
    let clock = DeterministicMockExperienceClock(
      now: releaseDate.addingTimeInterval(-60)
    )
    let runtime = DailyMemoryRuntime(clock: clock)
    let revision = ExperienceTestFixtures.revision(40)

    #expect(
      await runtime.compose(
        state: state,
        timeZone: ExperienceTestFixtures.timeZone,
        deviceRole: .iPhone,
        authoredRevision: revision
      ) == .unavailable(.beforeReleaseTime)
    )

    await clock.advance(by: 60)
    #expect(
      await runtime.compose(
        state: state,
        timeZone: ExperienceTestFixtures.timeZone,
        deviceRole: .watch,
        authoredRevision: revision
      ) == .unavailable(.watchWaitingForSync)
    )

    let first = await runtime.compose(
      state: state,
      timeZone: ExperienceTestFixtures.timeZone,
      deviceRole: .iPhone,
      authoredRevision: revision
    )
    let repeated = await runtime.compose(
      state: state,
      timeZone: ExperienceTestFixtures.timeZone,
      deviceRole: .iPhone,
      authoredRevision: revision
    )
    guard case .sealed(let memory) = first else {
      Issue.record("Expected an iPhone-authored sealed memory")
      return
    }
    #expect(repeated == .alreadySealed(memory))
    await clock.advance(by: 120)
    #expect(
      await runtime.compose(
        state: state,
        timeZone: ExperienceTestFixtures.timeZone,
        deviceRole: .iPhone,
        authoredRevision: ExperienceTestFixtures.revision(41)
      ) == .alreadySealed(memory)
    )
    #expect(memory.localDay == LocalDay("2026-07-24"))
    #expect(memory.timeZoneIdentifier == "Asia/Shanghai")
    guard case .sealed(let content) = memory.lifecycle else {
      Issue.record("Expected sealed content")
      return
    }
    #expect(content.facts.count == 1)
    #expect(content.facts.first?.sourceEventID == event.header.recordID)
    #expect(content.narrative == "今天我们经过了一段很长的路。")

    var projected = state
    #expect(ProfileReducer.apply(.memory(memory), to: &projected) == .applied)
    #expect(projected.validate() == nil)
  }

  @Test("Reminder consumption does not remove daily-memory eligibility")
  func reminderStateIsIndependent() {
    let fact = ExperienceTestFixtures.fact(
      "presented-steps",
      observedAt: releaseDate.addingTimeInterval(-3_600)
    )
    let event = ExperienceTestFixtures.event(
      "presented-walk",
      observedAt: fact.observedAt,
      fact: fact,
      reminderState: .presented(at: fact.observedAt.addingTimeInterval(20))
    )
    let outcome = DailyMemoryCompositionPolicy().compose(
      state: ExperienceTestFixtures.state(
        facts: [fact],
        events: [event]
      ),
      at: releaseDate,
      timeZone: ExperienceTestFixtures.timeZone,
      deviceRole: .iPhone,
      authoredRevision: ExperienceTestFixtures.revision(41)
    )

    guard case .sealed(let memory) = outcome,
      case .sealed(let content) = memory.lifecycle
    else {
      Issue.record("Presented event should still be remembered")
      return
    }
    #expect(content.facts.first?.sourceEventID == event.header.recordID)
  }

  @Test("Late evidence cannot rewrite an existing sealed memory")
  func lateEvidenceCannotRewrite() throws {
    let firstFact = ExperienceTestFixtures.fact(
      "steps",
      observedAt: releaseDate.addingTimeInterval(-3_600)
    )
    let firstEvent = ExperienceTestFixtures.event(
      "walk",
      observedAt: firstFact.observedAt,
      fact: firstFact
    )
    let initialState = ExperienceTestFixtures.state(
      facts: [firstFact],
      events: [firstEvent]
    )
    let policy = DailyMemoryCompositionPolicy()
    let firstOutcome = policy.compose(
      state: initialState,
      at: releaseDate,
      timeZone: ExperienceTestFixtures.timeZone,
      deviceRole: .iPhone,
      authoredRevision: ExperienceTestFixtures.revision(42)
    )
    guard case .sealed(let sealed) = firstOutcome else {
      Issue.record("Expected initial memory")
      return
    }

    let lateFact = ExperienceTestFixtures.fact(
      "late-pause",
      observedAt: releaseDate.addingTimeInterval(-300),
      value: .broadMotion(.stationary)
    )
    let lateEvent = ExperienceTestFixtures.event(
      "late-event",
      observedAt: lateFact.observedAt,
      fact: lateFact,
      kind: .pausedTogether
    )
    let stateWithLateEvidence = ExperienceTestFixtures.state(
      facts: [firstFact, lateFact],
      events: [firstEvent, lateEvent],
      memories: [sealed]
    )
    #expect(stateWithLateEvidence.validate() == nil)

    let repeated = policy.compose(
      state: stateWithLateEvidence,
      at: releaseDate.addingTimeInterval(600),
      timeZone: ExperienceTestFixtures.timeZone,
      deviceRole: .iPhone,
      authoredRevision: ExperienceTestFixtures.revision(43)
    )
    #expect(repeated == .alreadySealed(sealed))
  }

  @Test("Disabled sensing and ineligible events cannot create a memory")
  func authorityAndEligibility() {
    let fact = ExperienceTestFixtures.fact(
      "steps",
      observedAt: releaseDate.addingTimeInterval(-3_600)
    )
    let terminalEvent = ExperienceTestFixtures.event(
      "walk",
      observedAt: fact.observedAt,
      fact: fact,
      reminderState: .expired(at: fact.observedAt.addingTimeInterval(121))
    )
    let policy = DailyMemoryCompositionPolicy()

    #expect(
      policy.compose(
        state: ExperienceTestFixtures.state(
          facts: [fact],
          events: [terminalEvent],
          sensingEnabled: false
        ),
        at: releaseDate,
        timeZone: ExperienceTestFixtures.timeZone,
        deviceRole: .iPhone,
        authoredRevision: ExperienceTestFixtures.revision(44)
      ) == .unavailable(.companionSensingDisabled)
    )

    let ineligible = ExperienceTestFixtures.event(
      "ineligible",
      observedAt: fact.observedAt,
      fact: fact,
      memoryEligibility: .ineligible
    )
    #expect(
      policy.compose(
        state: ExperienceTestFixtures.state(
          facts: [fact],
          events: [ineligible]
        ),
        at: releaseDate,
        timeZone: ExperienceTestFixtures.timeZone,
        deviceRole: .iPhone,
        authoredRevision: ExperienceTestFixtures.revision(45)
      ) == .unavailable(.noEligibleEvents)
    )
  }

  @Test("Step and sleep references are both retained in deterministic order")
  func healthSummaryFacts() {
    let stepFact = ExperienceTestFixtures.fact(
      "steps",
      observedAt: releaseDate.addingTimeInterval(-4_000)
    )
    let sleepFact = ExperienceTestFixtures.fact(
      "sleep",
      observedAt: releaseDate.addingTimeInterval(-3_000),
      value: .sleepDuration(7.5 * 3_600)
    )
    let walk = ExperienceTestFixtures.event(
      "walk",
      observedAt: stepFact.observedAt,
      fact: stepFact
    )
    let sleep = ExperienceTestFixtures.event(
      "sleep-reflection",
      observedAt: sleepFact.observedAt,
      fact: sleepFact,
      kind: .sleepReflection
    )

    let outcome = DailyMemoryCompositionPolicy().compose(
      state: ExperienceTestFixtures.state(
        facts: [sleepFact, stepFact],
        events: [sleep, walk]
      ),
      at: releaseDate,
      timeZone: ExperienceTestFixtures.timeZone,
      deviceRole: .iPhone,
      authoredRevision: ExperienceTestFixtures.revision(46)
    )
    guard case .sealed(let memory) = outcome,
      case .sealed(let content) = memory.lifecycle
    else {
      Issue.record("Expected step and sleep memory")
      return
    }
    #expect(content.facts.map(\.kind) == [.stepSummary, .sleepDuration])
  }

  @Test("Narrative ignores unrelated facts from another day")
  func narrativeUsesOnlyReferencedFacts() {
    let pauseFact = ExperienceTestFixtures.fact(
      "current-pause",
      observedAt: releaseDate.addingTimeInterval(-600),
      value: .broadMotion(.stationary)
    )
    let pause = ExperienceTestFixtures.event(
      "current-pause-event",
      observedAt: pauseFact.observedAt,
      fact: pauseFact,
      kind: .pausedTogether
    )
    let unrelatedSteps = ExperienceTestFixtures.fact(
      "yesterday-steps",
      observedAt: releaseDate.addingTimeInterval(-24 * 60 * 60),
      value: .stepTotal(12_000)
    )

    let outcome = DailyMemoryCompositionPolicy().compose(
      state: ExperienceTestFixtures.state(
        facts: [unrelatedSteps, pauseFact],
        events: [pause]
      ),
      at: releaseDate,
      timeZone: ExperienceTestFixtures.timeZone,
      deviceRole: .iPhone,
      authoredRevision: ExperienceTestFixtures.revision(47)
    )
    guard case .sealed(let memory) = outcome,
      case .sealed(let content) = memory.lifecycle
    else {
      Issue.record("Expected a pause memory")
      return
    }

    #expect(content.narrative == "今天你停下来的时候，我也陪你坐了一会儿。")
    #expect(content.facts.map(\.evidenceID) == [pauseFact.header.recordID])
  }
}
