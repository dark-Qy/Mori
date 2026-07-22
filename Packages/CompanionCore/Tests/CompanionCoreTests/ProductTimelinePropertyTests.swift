import Domain
import Foundation
import Growth
import MockKit
import Persistence
import Rules
import Story
import Testing

@Suite("Deterministic product event timelines")
struct ProductTimelinePropertyTests {
  @Test(
    "Product event timeline preserves domain and persistence invariants",
    arguments: 0..<1_000
  )
  func productEventTimeline(seed: Int) throws {
    let timeline = makeTimeline(seed: UInt64(seed))
    let rebuilt = makeTimeline(seed: UInt64(seed))

    #expect(
      timeline == rebuilt,
      "seed=\(seed): rebuilding a fixed seed changed the generated timeline"
    )
    try verify(timeline)
  }

  @Test("The fixed 1,000-seed corpus is distinct and covers every required category")
  func timelineCorpusCoverage() {
    var observedCoverage: Set<TimelineCoverage> = []
    var fingerprints: Set<[UUID]> = []
    var observedRandomDraws: Set<String> = []

    for seed in 0..<1_000 {
      let timeline = makeTimeline(seed: UInt64(seed))
      fingerprints.insert(timeline.arrivals.map(\.eventID))
      observedCoverage.formUnion(timeline.coverage)
      observedRandomDraws.insert(timeline.randomDraw ?? "none")
    }

    #expect(fingerprints.count == 1_000, "all 1,000 seeds must produce distinct event timelines")
    #expect(
      observedCoverage == Set(TimelineCoverage.allCases),
      "the fixed seed corpus must exercise every required timeline category"
    )
    #expect(
      observedRandomDraws == ["lost_ball", "rain_walk", "none"],
      "overlapping eligibility must cover each candidate and the no-selection path"
    )
  }

  private func verify(_ timeline: ProductTimeline) throws {
    let context = "seed=\(timeline.seed)"
    let ledgerCodec = EventLedgerCodec()
    let stateCodec = CompanionStateCodec()
    let reducer = CompanionReducer()
    var ledger = try EventLedger()
    var previousGrowth = timeline.initialState.growth

    for (arrivalIndex, event) in timeline.arrivals.enumerated() {
      try ledger.append(event)

      let ledgerData = try ledgerCodec.encode(ledger)
      let restoredLedger = try ledgerCodec.decode(ledgerData)
      #expect(
        restoredLedger == ledger,
        "\(context), arrival=\(arrivalIndex): ledger failed its round trip"
      )
      #expect(
        restoredLedger.events == restoredLedger.events.sorted(by: EventEnvelope.canonicalOrder),
        "\(context), arrival=\(arrivalIndex): ledger lost canonical order"
      )

      let state = try reducer.replay(restoredLedger.events, from: timeline.initialState)
      #expect(
        state.processedEventIDs.count == restoredLedger.events.count,
        "\(context), arrival=\(arrivalIndex): an accepted ledger event was not processed"
      )
      #expect(
        state.growth.vitality >= previousGrowth.vitality
          && state.growth.bond >= previousGrowth.bond
          && state.growth.insight >= previousGrowth.insight,
        "\(context), arrival=\(arrivalIndex): appending an event removed earned growth"
      )
      #expect(
        state.vitalityAwardByDay.values.allSatisfy { (0...5).contains($0) },
        "\(context), arrival=\(arrivalIndex): a health-day award exceeded the configured cap"
      )

      let stateData = try stateCodec.encode(state)
      #expect(
        try stateCodec.encode(stateCodec.decode(stateData)) == stateData,
        "\(context), arrival=\(arrivalIndex): state encoding was not canonical"
      )

      let legacyData = try JSONEncoder().encode(
        PersistedCompanionState(schemaVersion: 0, state: state)
      )
      let migrated = try stateCodec.decode(
        legacyData,
        migrator: TimelineFixtureMigration(currentData: stateData)
      )
      #expect(
        migrated == state,
        "\(context), arrival=\(arrivalIndex): the supported migration path changed state"
      )
      previousGrowth = state.growth
    }

    let finalState = try reducer.replay(ledger.events, from: timeline.initialState)
    let directReplay = try reducer.replay(timeline.arrivals, from: timeline.initialState)
    let reversedReplay = try reducer.replay(
      Array(timeline.arrivals.reversed()),
      from: timeline.initialState
    )
    let rebuiltLedger = try EventLedger(events: timeline.arrivals)

    #expect(finalState == directReplay, "\(context): duplicate and late arrivals changed replay")
    #expect(finalState == reversedReplay, "\(context): reversed arrival order changed replay")
    #expect(rebuiltLedger == ledger, "\(context): incremental and batch ledger builds diverged")
    #expect(
      ledger.events.count == Set(timeline.arrivals.map(\.eventID)).count,
      "\(context): duplicate event IDs were persisted more than once"
    )
    #expect(
      timeline.arrivals.count > Set(timeline.arrivals.map(\.eventID)).count,
      "\(context): generated timeline did not contain a duplicate delivery"
    )
    #expect(
      timeline.arrivals.contains { $0.recordedAt.timeIntervalSince($0.occurredAt) >= 86_400 },
      "\(context): generated timeline did not contain a late delivery"
    )
    #expect(
      zip(timeline.arrivals, timeline.arrivals.dropFirst()).contains {
        $1.occurredAt < $0.occurredAt
      },
      "\(context): generated arrival stream never moved backward in event time"
    )
    #expect(
      zip(ledger.events, ledger.events.dropFirst()).contains {
        $1.occurredAt.timeIntervalSince($0.occurredAt) >= 30 * 86_400
      },
      "\(context): generated timeline did not contain long inactivity"
    )
    #expect(
      finalState.vitalityAwardByDay[timeline.cappedRewardDay.rawValue] == 5,
      "\(context): repeated snapshots or workouts changed the daily health cap"
    )
    #expect(
      !finalState.completedHabitDays.contains(timeline.expiredOpportunityDay),
      "\(context): an expired opportunity was materialized without a completion event"
    )
    #expect(
      !finalState.completedHabitDays.contains(timeline.missingDay)
        && finalState.vitalityAwardByDay[timeline.missingDay.rawValue] == nil,
      "\(context): a missing day was converted into zero-valued activity"
    )
    #expect(
      finalState.completedHabitDays.contains(timeline.returnDay),
      "\(context): a valid action after long inactivity was not accepted"
    )
    #expect(
      finalState.commitments.first?.status == timeline.expectedCommitmentStatus,
      "\(context): commitment transition did not reach the expected terminal status"
    )
    #expect(
      timeline.randomDraw == timeline.reversedCandidateDraw,
      "\(context): overlapping random eligibility depended on candidate order"
    )
    #expect(
      SoccerSideStoryRule().qualifyingWorkout(in: timeline.workoutSnapshot)?.id
        == timeline.expectedQualifyingWorkoutID,
      "\(context): repeated or reordered workouts changed soccer eligibility"
    )

    verifyTemporalObservation(
      timeline.temporalObservation,
      finalState: finalState,
      context: context
    )
  }

  private func verifyTemporalObservation(
    _ observation: TemporalObservation,
    finalState: CompanionState,
    context: String
  ) {
    switch observation {
    case .midnight(let before, let after, let timeZone):
      #expect(
        LocalDay.containing(before, in: timeZone) < LocalDay.containing(after, in: timeZone),
        "\(context): crossing local midnight did not advance the settlement day"
      )
      #expect(
        finalState.vitalityAwardByDay[LocalDay.containing(before, in: timeZone).rawValue] != nil
          && finalState.vitalityAwardByDay[LocalDay.containing(after, in: timeZone).rawValue]
            != nil,
        "\(context): both sides of midnight must settle as real health events"
      )

    case .springDST(let before, let after, let timeZone):
      #expect(localHour(before, in: timeZone) == 1, "\(context): invalid spring-DST fixture")
      #expect(localHour(after, in: timeZone) == 3, "\(context): DST gap was treated as 02:xx")
      #expect(
        LocalDay.containing(before, in: timeZone) == LocalDay.containing(after, in: timeZone),
        "\(context): spring DST changed the local calendar day"
      )
      #expect(
        finalState.vitalityAwardByDay[LocalDay.containing(before, in: timeZone).rawValue] != nil,
        "\(context): spring-DST health events were not settled"
      )

    case .fallDST(let first, let second, let timeZone):
      #expect(localHour(first, in: timeZone) == 1, "\(context): invalid fall-DST fixture")
      #expect(localHour(second, in: timeZone) == 1, "\(context): repeated hour was not observed")
      #expect(
        timeZone.secondsFromGMT(for: first) != timeZone.secondsFromGMT(for: second),
        "\(context): repeated fall-DST hours must have distinct UTC offsets"
      )
      #expect(
        finalState.vitalityAwardByDay[LocalDay.containing(first, in: timeZone).rawValue] != nil,
        "\(context): fall-DST health events were not settled"
      )

    case .timeZoneChange(let instant, let first, let second):
      #expect(
        LocalDay.containing(instant, in: first) != LocalDay.containing(instant, in: second),
        "\(context): time-zone travel fixture must span two local days"
      )
      #expect(
        finalState.vitalityAwardByDay[LocalDay.containing(instant, in: first).rawValue] != nil
          && finalState.vitalityAwardByDay[LocalDay.containing(instant, in: second).rawValue]
            != nil,
        "\(context): each time-zone interpretation must settle its explicit local day"
      )

    case .clockRollback(let firstArrival, let secondArrival):
      #expect(
        secondArrival.occurredAt < firstArrival.occurredAt
          && secondArrival.recordedAt > firstArrival.recordedAt,
        "\(context): rollback fixture must arrive later with an earlier wall-clock occurrence"
      )
      #expect(
        finalState.vitalityAwardByDay[
          LocalDay.containing(firstArrival.occurredAt, in: TimeZone(secondsFromGMT: 0)!).rawValue
        ] != nil,
        "\(context): clock-rollback health events were not settled"
      )
    }
  }

  private func makeTimeline(seed: UInt64) -> ProductTimeline {
    let utc = TimeZone(secondsFromGMT: 0)!
    let base = localDate(2025, 1, 10, 12, 0, in: utc)
    var ids = TimelineIDSource(seed: seed)
    var random = SeededRandomSource(seed: seed)
    var arrivals: [EventEnvelope] = []
    var coverage: Set<TimelineCoverage> = [
      .duplicateAndLate,
      .missingAndInactive,
      .repeatedWorkoutAndCap,
      .expiredOpportunity,
      .randomEligibilityOverlap,
      .persistenceAndMigration,
    ]

    let cappedRewardDay = LocalDay.containing(base, in: utc)
    let workoutOne = WorkoutSummary(
      id: ids.next(),
      activity: .soccer,
      startedAt: base.addingTimeInterval(300),
      durationMinutes: 25
    )
    let workoutTwo = WorkoutSummary(
      id: ids.next(),
      activity: .soccer,
      startedAt: base.addingTimeInterval(900),
      durationMinutes: 35
    )
    let workoutSnapshot = HealthSnapshot(
      capturedAt: base.addingTimeInterval(1_200),
      timeZoneIdentifier: utc.identifier,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      sleepMinutes: 420,
      steps: 8_000,
      activeMinutes: 30,
      workouts: [workoutOne, workoutTwo, workoutOne]
    )
    let strongHealthEvent = envelope(
      id: ids.next(),
      occurredAt: workoutSnapshot.capturedAt,
      payload: .healthSnapshotReceived(workoutSnapshot)
    )
    let repeatedWorkoutSnapshot = HealthSnapshot(
      capturedAt: base.addingTimeInterval(1_800),
      timeZoneIdentifier: utc.identifier,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .partial,
      steps: 8_000,
      workouts: [workoutTwo, workoutOne, workoutTwo]
    )
    let repeatedHealthEvent = envelope(
      id: ids.next(),
      occurredAt: repeatedWorkoutSnapshot.capturedAt,
      payload: .healthSnapshotReceived(repeatedWorkoutSnapshot)
    )

    let lateSnapshot = HealthSnapshot(
      capturedAt: base.addingTimeInterval(120),
      timeZoneIdentifier: utc.identifier,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .partial,
      steps: 8_000
    )
    let lateEvent = envelope(
      id: ids.next(),
      occurredAt: lateSnapshot.capturedAt,
      recordedAt: base.addingTimeInterval(7 * 86_400),
      payload: .healthSnapshotReceived(lateSnapshot)
    )

    let firstBeat = envelope(
      id: ids.next(),
      occurredAt: base.addingTimeInterval(2_000),
      payload: .storyBeatCompleted(
        StoryBeatCompletion(beatID: "main.day-1.awakening", chapter: 1)
      )
    )
    let secondBeat = envelope(
      id: ids.next(),
      occurredAt: base.addingTimeInterval(2_100),
      payload: .storyBeatCompleted(
        StoryBeatCompletion(beatID: "main.day-2.first-step", chapter: 2)
      )
    )
    let firstArrival = envelope(
      id: ids.next(),
      occurredAt: base.addingTimeInterval(3_000),
      recordedAt: base.addingTimeInterval(3_000),
      payload: .petInteracted(PetInteraction(kind: "wave"))
    )
    let rollbackArrival = envelope(
      id: ids.next(),
      occurredAt: base.addingTimeInterval(2_400),
      recordedAt: base.addingTimeInterval(3_600),
      payload: .petInteracted(PetInteraction(kind: "clock-correction"))
    )

    // Arrival order intentionally differs from canonical occurrence order and includes exact
    // duplicates. EventLedger is responsible for canonicalizing and deduplicating the stream.
    arrivals.append(contentsOf: [secondBeat, strongHealthEvent, strongHealthEvent, firstArrival])
    arrivals.append(contentsOf: [lateEvent, firstBeat, rollbackArrival, repeatedHealthEvent])

    let candidates = [
      SideStoryCandidate(id: "lost_ball", probability: 0.55),
      SideStoryCandidate(id: "rain_walk", probability: 0.45),
    ]
    var forwardRandom = SeededRandomSource(seed: seed ^ 0xA11C_E55E)
    var reverseRandom = SeededRandomSource(seed: seed ^ 0xA11C_E55E)
    let randomDraw = SideStoryLottery().draw(from: candidates, using: &forwardRandom)
    let reversedCandidateDraw = SideStoryLottery().draw(
      from: candidates.reversed(),
      using: &reverseRandom
    )
    if randomDraw == "lost_ball" {
      arrivals.append(
        envelope(
          id: ids.next(),
          occurredAt: base.addingTimeInterval(2_200),
          payload: .sideStoryUnlocked(
            SideStoryUnlock(
              storyID: "lost_ball",
              ruleID: SoccerSideStoryRule.ruleID,
              ruleSetVersion: SoccerSideStoryRule.ruleSetVersion,
              triggerEventID: strongHealthEvent.eventID
            )
          )
        )
      )
    }

    let expiredOpportunityDay = LocalDay.containing(
      base.addingTimeInterval(86_400),
      in: utc
    )
    let missingDay = LocalDay.containing(base.addingTimeInterval(10 * 86_400), in: utc)
    let returnDate = base.addingTimeInterval(340 * 86_400)
    let returnDay = LocalDay.containing(returnDate, in: utc)
    arrivals.append(
      envelope(
        id: ids.next(),
        occurredAt: returnDate,
        payload: .dailyHabitCompleted(
          DailyHabitCompletion(kind: .companionCheckIn, localDay: returnDay)
        )
      )
    )

    let acceptanceDate = base.addingTimeInterval(4 * 3_600)
    let commitmentID = ids.next()
    let targetDay = LocalDay.containing(acceptanceDate, in: utc)
    arrivals.append(
      envelope(
        id: ids.next(),
        occurredAt: acceptanceDate,
        payload: .commitmentAccepted(
          CommitmentAcceptance(
            commitmentID: commitmentID,
            kind: CommitmentKind.allCases[Int(seed % UInt64(CommitmentKind.allCases.count))],
            targetDay: targetDay,
            timeZoneIdentifier: utc.identifier
          )
        )
      )
    )

    let expectedCommitmentStatus: CommitmentStatus
    switch seed % 4 {
    case 0:
      coverage.formUnion([.commitmentMissed, .commitmentRepaired])
      let missedDate = acceptanceDate.addingTimeInterval(2 * 86_400)
      arrivals.append(
        commitmentResolution(
          id: ids.next(),
          commitmentID: commitmentID,
          kind: .missed,
          at: missedDate
        )
      )
      arrivals.append(
        commitmentResolution(
          id: ids.next(),
          commitmentID: commitmentID,
          kind: .repaired,
          at: missedDate.addingTimeInterval(60)
        )
      )
      expectedCommitmentStatus = .repaired

    case 1:
      coverage.formUnion([.commitmentMissed, .commitmentResized])
      let missedDate = acceptanceDate.addingTimeInterval(2 * 86_400)
      let resizedDate = missedDate.addingTimeInterval(60)
      let resizedTarget = LocalDay.containing(
        resizedDate.addingTimeInterval(2 * 86_400),
        in: utc
      )
      arrivals.append(
        commitmentResolution(
          id: ids.next(),
          commitmentID: commitmentID,
          kind: .missed,
          at: missedDate
        )
      )
      arrivals.append(
        commitmentResolution(
          id: ids.next(),
          commitmentID: commitmentID,
          kind: .resized,
          at: resizedDate,
          newTargetDay: resizedTarget
        )
      )
      arrivals.append(
        commitmentResolution(
          id: ids.next(),
          commitmentID: commitmentID,
          kind: .fulfilled,
          at: resizedDate.addingTimeInterval(60)
        )
      )
      expectedCommitmentStatus = .fulfilled

    case 2:
      coverage.insert(.commitmentReleased)
      arrivals.append(
        commitmentResolution(
          id: ids.next(),
          commitmentID: commitmentID,
          kind: .released,
          at: acceptanceDate.addingTimeInterval(60)
        )
      )
      expectedCommitmentStatus = .released

    default:
      coverage.formUnion([.commitmentMissed, .commitmentReleased])
      let missedDate = acceptanceDate.addingTimeInterval(2 * 86_400)
      arrivals.append(
        commitmentResolution(
          id: ids.next(),
          commitmentID: commitmentID,
          kind: .missed,
          at: missedDate
        )
      )
      arrivals.append(
        commitmentResolution(
          id: ids.next(),
          commitmentID: commitmentID,
          kind: .released,
          at: missedDate.addingTimeInterval(60)
        )
      )
      expectedCommitmentStatus = .released
    }
    coverage.insert(.commitmentAccepted)

    let temporalObservation = addTemporalEvents(
      variant: Int(seed % 5),
      ids: &ids,
      arrivals: &arrivals
    )
    switch temporalObservation {
    case .midnight:
      coverage.insert(.midnight)
    case .springDST, .fallDST:
      coverage.insert(.daylightSaving)
    case .timeZoneChange:
      coverage.insert(.timeZoneChange)
    case .clockRollback:
      coverage.insert(.clockRollback)
    }

    // Consume the seeded source in the product data itself, not only in the lottery. This varies
    // the harmless interaction vocabulary while keeping every generated event replay-stable.
    let interactionKinds = ["pat", "check-in", "wave", "rest-return"]
    let kindIndex = min(Int(random.nextUnitInterval() * 4), interactionKinds.count - 1)
    arrivals.append(
      envelope(
        id: ids.next(),
        occurredAt: returnDate.addingTimeInterval(60),
        payload: .petInteracted(PetInteraction(kind: interactionKinds[kindIndex]))
      )
    )

    return ProductTimeline(
      seed: seed,
      arrivals: arrivals,
      initialState: CompanionState(growth: GrowthState(vitality: 7, bond: 2, insight: 3)),
      coverage: coverage,
      cappedRewardDay: cappedRewardDay,
      expiredOpportunityDay: expiredOpportunityDay,
      missingDay: missingDay,
      returnDay: returnDay,
      expectedCommitmentStatus: expectedCommitmentStatus,
      randomDraw: randomDraw,
      reversedCandidateDraw: reversedCandidateDraw,
      workoutSnapshot: workoutSnapshot,
      expectedQualifyingWorkoutID: workoutTwo.id,
      temporalObservation: temporalObservation
    )
  }

  private func addTemporalEvents(
    variant: Int,
    ids: inout TimelineIDSource,
    arrivals: inout [EventEnvelope]
  ) -> TemporalObservation {
    let utc = TimeZone(secondsFromGMT: 0)!

    switch variant {
    case 0:
      let timeZone = TimeZone(identifier: "Asia/Shanghai")!
      let before = localDate(2025, 2, 1, 23, 59, in: timeZone)
      let after = before.addingTimeInterval(120)
      arrivals.append(temporalHealthEvent(id: ids.next(), at: before, timeZone: timeZone))
      arrivals.append(temporalHealthEvent(id: ids.next(), at: after, timeZone: timeZone))
      return .midnight(before: before, after: after, timeZone: timeZone)

    case 1:
      let timeZone = TimeZone(identifier: "America/Los_Angeles")!
      let before = localDate(2025, 3, 9, 1, 55, in: timeZone)
      let after = before.addingTimeInterval(10 * 60)
      arrivals.append(temporalHealthEvent(id: ids.next(), at: before, timeZone: timeZone))
      arrivals.append(temporalHealthEvent(id: ids.next(), at: after, timeZone: timeZone))
      return .springDST(before: before, after: after, timeZone: timeZone)

    case 2:
      let timeZone = TimeZone(identifier: "America/Los_Angeles")!
      let first = localDate(2025, 11, 2, 8, 30, in: utc)
      let second = localDate(2025, 11, 2, 9, 30, in: utc)
      arrivals.append(temporalHealthEvent(id: ids.next(), at: first, timeZone: timeZone))
      arrivals.append(temporalHealthEvent(id: ids.next(), at: second, timeZone: timeZone))
      return .fallDST(first: first, second: second, timeZone: timeZone)

    case 3:
      let instant = localDate(2025, 6, 15, 6, 0, in: utc)
      let first = TimeZone(identifier: "America/Los_Angeles")!
      let second = TimeZone(identifier: "Asia/Tokyo")!
      arrivals.append(temporalHealthEvent(id: ids.next(), at: instant, timeZone: first))
      arrivals.append(temporalHealthEvent(id: ids.next(), at: instant, timeZone: second))
      return .timeZoneChange(instant: instant, first: first, second: second)

    default:
      let first = temporalHealthEvent(
        id: ids.next(),
        at: localDate(2025, 7, 1, 12, 5, in: utc),
        timeZone: utc
      )
      let second = temporalHealthEvent(
        id: ids.next(),
        at: localDate(2025, 7, 1, 11, 55, in: utc),
        timeZone: utc,
        recordedAt: localDate(2025, 7, 1, 12, 10, in: utc),
      )
      arrivals.append(first)
      arrivals.append(second)
      return .clockRollback(firstArrival: first, secondArrival: second)
    }
  }

  private func temporalHealthEvent(
    id: UUID,
    at date: Date,
    timeZone: TimeZone,
    recordedAt: Date? = nil
  ) -> EventEnvelope {
    let snapshot = HealthSnapshot(
      capturedAt: date,
      timeZoneIdentifier: timeZone.identifier,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .partial,
      steps: 4_000
    )
    return envelope(
      id: id,
      occurredAt: date,
      recordedAt: recordedAt,
      payload: .healthSnapshotReceived(snapshot)
    )
  }

  private func commitmentResolution(
    id: UUID,
    commitmentID: UUID,
    kind: CommitmentResolutionKind,
    at date: Date,
    newTargetDay: LocalDay? = nil
  ) -> EventEnvelope {
    envelope(
      id: id,
      occurredAt: date,
      payload: .commitmentResolved(
        CommitmentResolution(
          commitmentID: commitmentID,
          kind: kind,
          newTargetDay: newTargetDay
        )
      )
    )
  }

  private func envelope(
    id: UUID,
    occurredAt: Date,
    recordedAt: Date? = nil,
    payload: DomainEvent
  ) -> EventEnvelope {
    EventEnvelope(
      eventID: id,
      occurredAt: occurredAt,
      recordedAt: recordedAt,
      source: .mock,
      payload: payload
    )
  }

  private func localDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    in timeZone: TimeZone
  ) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(
      from: DateComponents(
        timeZone: timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
      )
    )!
  }

  private func localHour(_ date: Date, in timeZone: TimeZone) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.component(.hour, from: date)
  }
}

private struct ProductTimeline: Equatable {
  var seed: UInt64
  var arrivals: [EventEnvelope]
  var initialState: CompanionState
  var coverage: Set<TimelineCoverage>
  var cappedRewardDay: LocalDay
  var expiredOpportunityDay: LocalDay
  var missingDay: LocalDay
  var returnDay: LocalDay
  var expectedCommitmentStatus: CommitmentStatus
  var randomDraw: String?
  var reversedCandidateDraw: String?
  var workoutSnapshot: HealthSnapshot
  var expectedQualifyingWorkoutID: UUID
  var temporalObservation: TemporalObservation
}

private enum TimelineCoverage: String, CaseIterable {
  case duplicateAndLate
  case midnight
  case daylightSaving
  case timeZoneChange
  case clockRollback
  case missingAndInactive
  case repeatedWorkoutAndCap
  case expiredOpportunity
  case commitmentAccepted
  case commitmentMissed
  case commitmentRepaired
  case commitmentResized
  case commitmentReleased
  case randomEligibilityOverlap
  case persistenceAndMigration
}

private enum TemporalObservation: Equatable {
  case midnight(before: Date, after: Date, timeZone: TimeZone)
  case springDST(before: Date, after: Date, timeZone: TimeZone)
  case fallDST(first: Date, second: Date, timeZone: TimeZone)
  case timeZoneChange(instant: Date, first: TimeZone, second: TimeZone)
  case clockRollback(firstArrival: EventEnvelope, secondArrival: EventEnvelope)
}

private struct TimelineIDSource {
  var seed: UInt64
  var index: UInt64 = 0

  mutating func next() -> UUID {
    index += 1
    let high = 0xA11C_E000_0000_0000 | seed
    let low = index
    return UUID(
      uuid: (
        byte(high, 56), byte(high, 48), byte(high, 40), byte(high, 32),
        byte(high, 24), byte(high, 16), byte(high, 8), byte(high, 0),
        byte(low, 56), byte(low, 48), byte(low, 40), byte(low, 32),
        byte(low, 24), byte(low, 16), byte(low, 8), byte(low, 0)
      )
    )
  }

  private func byte(_ value: UInt64, _ shift: UInt64) -> UInt8 {
    UInt8(truncatingIfNeeded: value >> shift)
  }
}

private struct TimelineFixtureMigration: CompanionStateMigrating {
  var currentData: Data

  func migrate(_ data: Data, from sourceVersion: Int, to targetVersion: Int) throws -> Data {
    guard sourceVersion == 0, targetVersion == PersistedCompanionState.currentSchemaVersion else {
      throw TimelineMigrationError.unexpectedPath(from: sourceVersion, to: targetVersion)
    }
    return currentData
  }
}

private enum TimelineMigrationError: Error {
  case unexpectedPath(from: Int, to: Int)
}
