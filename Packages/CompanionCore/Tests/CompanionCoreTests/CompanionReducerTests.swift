import Domain
import Foundation
import Growth
import MockKit
import Testing

@Suite("Companion event reducer")
struct CompanionReducerTests {
  private let reducer = CompanionReducer()
  private let start = Date(timeIntervalSince1970: 1_750_000_000)

  @Test("Duplicate event IDs are idempotent")
  func duplicateEvents() throws {
    let event = healthEvent(id: uuid(1), snapshot: HealthFixtures.normal(at: start))
    let state = try reducer.replay([event, event])

    #expect(state.growth.vitality == 5)
    #expect(state.processedEventIDs == [event.eventID])
  }

  @Test("Distinct snapshots settle only the positive daily award difference")
  func dailyAwardCap() throws {
    let morning = HealthSnapshot(
      capturedAt: start,
      localDay: LocalDay(rawValue: "2025-06-15"),
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      steps: 8_000
    )
    let evening = HealthSnapshot(
      capturedAt: start.addingTimeInterval(10_000),
      localDay: LocalDay(rawValue: "2025-06-15"),
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      sleepMinutes: 420,
      steps: 8_000,
      activeMinutes: 30
    )

    let state = try reducer.replay([
      healthEvent(id: uuid(10), snapshot: morning),
      healthEvent(id: uuid(11), snapshot: evening),
      healthEvent(id: uuid(12), snapshot: evening),
    ])

    #expect(state.growth.vitality == 5)
    #expect(state.vitalityAwardByDay == ["2025-06-15": 5])
  }

  @Test("A later-arriving weaker snapshot cannot reduce or duplicate a settled award")
  func lateSnapshotDoesNotChangeSettledAward() throws {
    let fullAward = HealthSnapshot(
      capturedAt: start,
      localDay: LocalDay(rawValue: "2025-06-15"),
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      sleepMinutes: 420,
      steps: 8_000,
      activeMinutes: 30
    )
    let partialAward = HealthSnapshot(
      capturedAt: start.addingTimeInterval(1),
      localDay: LocalDay(rawValue: "2025-06-15"),
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .partial,
      steps: 8_000
    )

    let state = try reducer.replay([
      healthEvent(id: uuid(13), snapshot: fullAward),
      healthEvent(id: uuid(14), snapshot: partialAward),
    ])

    #expect(state.growth.vitality == 5)
    #expect(state.vitalityAwardByDay["2025-06-15"] == 5)
  }

  @Test("A later neutral entry cannot hide an explicit care request")
  func preservesLatestCareStateOfMind() throws {
    let stressed = StateOfMindSample(
      id: uuid(18),
      recordedAt: start.addingTimeInterval(-60),
      valence: -0.6,
      labels: [.stressed]
    )
    let neutral = StateOfMindSample(
      id: uuid(19),
      recordedAt: start,
      valence: 0.1,
      labels: [.other]
    )
    let snapshot = HealthSnapshot(
      capturedAt: start,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      stateOfMindSamples: [stressed, neutral]
    )

    let state = try reducer.replay([healthEvent(id: uuid(20), snapshot: snapshot)])

    #expect(state.lastStateOfMind == stressed)
  }

  @Test("Scheduling care consumes its State of Mind sample exactly once")
  func consumesCareSample() throws {
    let sampleID = uuid(21)
    let scheduled = EventEnvelope(
      eventID: uuid(22),
      occurredAt: start,
      source: .phone,
      payload: .stateOfMindCareScheduled(StateOfMindCareSchedule(sampleID: sampleID))
    )

    let state = try reducer.replay([scheduled, scheduled])

    #expect(state.handledStateOfMindSampleIDs == [sampleID])
  }

  @Test("Batch replay canonicalizes event order")
  func orderedReplay() throws {
    let firstDate = start
    let secondDate = start.addingTimeInterval(3_600)
    let first = EventEnvelope(
      eventID: uuid(1),
      occurredAt: firstDate,
      source: .mock,
      payload: .healthSnapshotReceived(HealthFixtures.lowSleep(at: firstDate))
    )
    let second = EventEnvelope(
      eventID: uuid(2),
      occurredAt: secondDate,
      source: .mock,
      payload: .healthSnapshotReceived(HealthFixtures.normal(at: secondDate))
    )

    let chronological = try reducer.replay([first, second])
    let reversed = try reducer.replay([second, first])

    #expect(chronological == reversed)
    #expect(chronological.activeTheme == .activity)
    #expect(chronological.lastDecisionTrace?.evaluatedAt == secondDate)
  }

  @Test("Story beat identity prevents duplicate story state")
  func duplicateStoryBeat() throws {
    let firstChapter = EventEnvelope(
      eventID: uuid(3),
      occurredAt: start,
      source: .watch,
      payload: .storyBeatCompleted(
        StoryBeatCompletion(beatID: "main.day-1.awakening", chapter: 1)
      )
    )
    let payload = DomainEvent.storyBeatCompleted(
      StoryBeatCompletion(
        beatID: "main.day-2.first-step",
        chapter: 2,
        memory: "We took the first step."
      )
    )
    let first = EventEnvelope(
      eventID: uuid(4),
      occurredAt: start.addingTimeInterval(1),
      source: .watch,
      payload: payload
    )
    let duplicateMeaning = EventEnvelope(
      eventID: uuid(5),
      occurredAt: start.addingTimeInterval(2),
      source: .phone,
      payload: payload
    )

    let state = try reducer.replay([firstChapter, first, duplicateMeaning])
    #expect(state.story.mainlineChapter == 2)
    #expect(state.story.completedBeatIDs.count == 2)
    #expect(state.story.memories == ["We took the first step."])
    #expect(state.growth.insight == 20)
  }

  @Test("One explicit daily habit awards once and never punishes another choice")
  func dailyHabitSettlesOnce() throws {
    let day = LocalDay(rawValue: "2025-06-15")!
    let first = EventEnvelope(
      eventID: uuid(30),
      occurredAt: start,
      source: .watch,
      payload: .dailyHabitCompleted(DailyHabitCompletion(kind: .microRest, localDay: day))
    )
    let secondChoice = EventEnvelope(
      eventID: uuid(31),
      occurredAt: start.addingTimeInterval(60),
      source: .watch,
      payload: .dailyHabitCompleted(DailyHabitCompletion(kind: .shortWalk, localDay: day))
    )

    let state = try reducer.replay([first, secondChoice])

    #expect(state.growth.vitality == 2)
    #expect(state.completedHabitDays == [day])
    #expect(state.processedEventIDs.contains(first.eventID))
    #expect(state.processedEventIDs.contains(secondChoice.eventID))
  }

  @Test("Unknown habit rule versions fail closed without an award")
  func invalidHabitRule() throws {
    let day = LocalDay(rawValue: "2025-06-15")!
    let event = EventEnvelope(
      eventID: uuid(32),
      occurredAt: start,
      source: .watch,
      payload: .dailyHabitCompleted(
        DailyHabitCompletion(kind: .windDown, localDay: day, ruleSetVersion: 99)
      )
    )

    let state = try reducer.replay([event])
    #expect(state.growth.vitality == 0)
    #expect(state.completedHabitDays.isEmpty)
  }

  @Test("A commitment requires explicit acceptance and does not award bond up front")
  func explicitCommitmentAcceptance() throws {
    let day = LocalDay(rawValue: "2025-06-15")!
    let firstID = uuid(40)
    let first = EventEnvelope(
      eventID: uuid(41),
      occurredAt: start,
      source: .watch,
      payload: .commitmentAccepted(
        CommitmentAcceptance(
          commitmentID: firstID,
          kind: .beginWindDown,
          targetDay: day,
          timeZoneIdentifier: "UTC"
        )
      )
    )
    let second = EventEnvelope(
      eventID: uuid(42),
      occurredAt: start.addingTimeInterval(60),
      source: .watch,
      payload: .commitmentAccepted(
        CommitmentAcceptance(
          commitmentID: uuid(43),
          kind: .takeShortWalk,
          targetDay: day,
          timeZoneIdentifier: "UTC"
        )
      )
    )

    let state = try reducer.replay([first, second])

    #expect(state.commitments.count == 1)
    #expect(state.commitments.first?.commitmentID == firstID)
    #expect(state.commitments.first?.status == .active)
    #expect(state.growth.bond == 0)
  }

  @Test("A missed commitment is remembered without loss and can be repaired once")
  func missedCommitmentRepair() throws {
    let day = LocalDay(rawValue: "2025-06-15")!
    let commitmentID = uuid(44)
    let acceptance = EventEnvelope(
      eventID: uuid(45),
      occurredAt: start,
      source: .watch,
      payload: .commitmentAccepted(
        CommitmentAcceptance(
          commitmentID: commitmentID,
          kind: .beginWindDown,
          targetDay: day,
          timeZoneIdentifier: "UTC"
        )
      )
    )
    let earlyMiss = EventEnvelope(
      eventID: uuid(46),
      occurredAt: start.addingTimeInterval(60),
      source: .watch,
      payload: .commitmentResolved(
        CommitmentResolution(commitmentID: commitmentID, kind: .missed)
      )
    )
    let validMiss = EventEnvelope(
      eventID: uuid(47),
      occurredAt: start.addingTimeInterval(86_400),
      source: .watch,
      payload: .commitmentResolved(
        CommitmentResolution(commitmentID: commitmentID, kind: .missed)
      )
    )
    let repair = EventEnvelope(
      eventID: uuid(48),
      occurredAt: start.addingTimeInterval(86_460),
      source: .watch,
      payload: .commitmentResolved(
        CommitmentResolution(commitmentID: commitmentID, kind: .repaired)
      )
    )

    let missed = try reducer.replay(
      [acceptance, earlyMiss, validMiss],
      from: CompanionState(growth: GrowthState(bond: 5))
    )
    #expect(missed.commitments.first?.status == .needsRepair)
    #expect(missed.growth.bond == 5)

    let repaired = try reducer.replay(
      [acceptance, earlyMiss, validMiss, repair, repair],
      from: CompanionState(growth: GrowthState(bond: 5))
    )
    #expect(repaired.commitments.first?.status == .repaired)
    #expect(repaired.growth.bond == 6)
  }

  @Test("Resizing a missed commitment reopens it without a reward")
  func resizeThenFulfillCommitment() throws {
    let commitmentID = uuid(49)
    let accepted = EventEnvelope(
      eventID: uuid(50),
      occurredAt: start,
      source: .watch,
      payload: .commitmentAccepted(
        CommitmentAcceptance(
          commitmentID: commitmentID,
          kind: .takeMicroRest,
          targetDay: LocalDay(rawValue: "2025-06-15")!,
          timeZoneIdentifier: "UTC"
        )
      )
    )
    let missed = EventEnvelope(
      eventID: uuid(51),
      occurredAt: start.addingTimeInterval(86_400),
      source: .watch,
      payload: .commitmentResolved(
        CommitmentResolution(commitmentID: commitmentID, kind: .missed)
      )
    )
    let resized = EventEnvelope(
      eventID: uuid(52),
      occurredAt: start.addingTimeInterval(86_460),
      source: .watch,
      payload: .commitmentResolved(
        CommitmentResolution(
          commitmentID: commitmentID,
          kind: .resized,
          newTargetDay: LocalDay(rawValue: "2025-06-17")!
        )
      )
    )
    let fulfilled = EventEnvelope(
      eventID: uuid(53),
      occurredAt: start.addingTimeInterval(90_000),
      source: .watch,
      payload: .commitmentResolved(
        CommitmentResolution(commitmentID: commitmentID, kind: .fulfilled)
      )
    )

    let resizedState = try reducer.replay([accepted, missed, resized])
    #expect(resizedState.commitments.first?.status == .active)
    #expect(resizedState.commitments.first?.targetDay == LocalDay(rawValue: "2025-06-17"))
    #expect(resizedState.growth.bond == 0)

    let fulfilledState = try reducer.replay([accepted, missed, resized, fulfilled])
    #expect(fulfilledState.commitments.first?.status == .fulfilled)
    #expect(fulfilledState.growth.bond == 3)
  }

  @Test("Unknown commitment rules fail closed")
  func invalidCommitmentRule() throws {
    let event = EventEnvelope(
      eventID: uuid(54),
      occurredAt: start,
      source: .watch,
      payload: .commitmentAccepted(
        CommitmentAcceptance(
          commitmentID: uuid(55),
          kind: .checkInWithMori,
          targetDay: LocalDay(rawValue: "2025-06-15")!,
          timeZoneIdentifier: "UTC",
          ruleSetVersion: 99
        )
      )
    )

    let state = try reducer.replay([event])
    #expect(state.commitments.isEmpty)
    #expect(state.growth.bond == 0)
  }

  @Test("Invalid commitment time zones fail closed instead of changing the promised day")
  func invalidCommitmentTimeZone() throws {
    let event = EventEnvelope(
      eventID: uuid(56),
      occurredAt: start,
      source: .watch,
      payload: .commitmentAccepted(
        CommitmentAcceptance(
          commitmentID: uuid(57),
          kind: .beginWindDown,
          targetDay: LocalDay(rawValue: "2025-06-15")!,
          timeZoneIdentifier: "Not/A-Time-Zone"
        )
      )
    )

    let state = try reducer.replay([event])
    #expect(state.commitments.isEmpty)
  }

  @Test("An overdue commitment must enter repair before it can earn bond")
  func overdueCommitmentCannotBeFulfilledDirectly() throws {
    let commitmentID = uuid(58)
    let accepted = EventEnvelope(
      eventID: uuid(59),
      occurredAt: start,
      source: .watch,
      payload: .commitmentAccepted(
        CommitmentAcceptance(
          commitmentID: commitmentID,
          kind: .takeShortWalk,
          targetDay: LocalDay(rawValue: "2025-06-15")!,
          timeZoneIdentifier: "UTC"
        )
      )
    )
    let overdueFulfillment = EventEnvelope(
      eventID: uuid(60),
      occurredAt: start.addingTimeInterval(86_400),
      source: .watch,
      payload: .commitmentResolved(
        CommitmentResolution(commitmentID: commitmentID, kind: .fulfilled)
      )
    )

    let state = try reducer.replay([accepted, overdueFulfillment])
    #expect(state.commitments.first?.status == .active)
    #expect(state.growth.bond == 0)
  }

  @Test("Mainline reducer rejects chapter jumps")
  func rejectsChapterJump() throws {
    let event = EventEnvelope(
      eventID: uuid(15),
      occurredAt: start,
      source: .mock,
      payload: .storyBeatCompleted(
        StoryBeatCompletion(beatID: "main.day-7.departure", chapter: 7)
      )
    )

    let state = try reducer.replay([event])
    #expect(state.story.mainlineChapter == 1)
    #expect(state.story.completedBeatIDs.isEmpty)
  }

  @Test("Side stories require a catalogued rule decision")
  func validatesSideStoryDecision() throws {
    let triggerID = uuid(20)
    let invalid = EventEnvelope(
      eventID: uuid(21),
      occurredAt: start,
      source: .mock,
      payload: .sideStoryUnlocked(
        SideStoryUnlock(
          storyID: "lost_ball",
          ruleID: "untrusted.rule",
          ruleSetVersion: 1,
          triggerEventID: triggerID
        )
      )
    )
    let valid = EventEnvelope(
      eventID: uuid(22),
      occurredAt: start.addingTimeInterval(1),
      source: .mock,
      payload: .sideStoryUnlocked(
        SideStoryUnlock(
          storyID: "lost_ball",
          ruleID: "phase1.story.soccer-workout",
          ruleSetVersion: 1,
          triggerEventID: triggerID
        )
      )
    )

    let state = try reducer.replay([invalid, valid])
    #expect(state.story.unlockedSideStoryIDs == ["lost_ball"])
  }

  @Test("Health snapshot schemas and settlement days fail closed")
  func validatesNestedHealthEnvelope() {
    let future = HealthSnapshot(
      schemaVersion: 99,
      capturedAt: start,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      steps: 8_000
    )
    let inconsistentDay = HealthSnapshot(
      capturedAt: start,
      localDay: LocalDay(rawValue: "2025-06-16"),
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      steps: 8_000
    )

    #expect(throws: CompanionReducerError.unsupportedHealthSnapshotSchema(99)) {
      try reducer.replay([healthEvent(id: uuid(16), snapshot: future)])
    }
    #expect(throws: CompanionReducerError.inconsistentHealthSettlementDay) {
      try reducer.replay([healthEvent(id: uuid(17), snapshot: inconsistentDay)])
    }
  }

  @Test("Unsupported event schemas are rejected")
  func unsupportedEventSchema() {
    let event = EventEnvelope(
      schemaVersion: 99,
      eventID: uuid(9),
      occurredAt: start,
      source: .mock,
      payload: .petInteracted(PetInteraction(kind: "tap"))
    )

    #expect(throws: CompanionReducerError.unsupportedEventSchema(99)) {
      try reducer.replay([event])
    }
  }

  @Test("Seven-day mock timeline replays exactly")
  func mockTimelineReplay() throws {
    let timeline = MockTimeline.sevenDayFixture(startingAt: start)

    let first = try timeline.replay()
    let second = try timeline.replay()

    #expect(first == second)
    #expect(first.processedEventIDs.count == 7)
    #expect(first.growth.vitality == 30)
  }

  private func healthEvent(id: UUID, snapshot: HealthSnapshot) -> EventEnvelope {
    EventEnvelope(
      eventID: id,
      occurredAt: snapshot.capturedAt,
      source: .mock,
      payload: .healthSnapshotReceived(snapshot)
    )
  }

  private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
  }
}
