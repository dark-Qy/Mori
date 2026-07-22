import AppRuntime
import Domain
import Foundation
import Persistence
import Testing

@Suite("Phase 1 authoritative progression")
struct PhaseOneProgressionTests {
  private let dayOne = Date(timeIntervalSince1970: 1_760_000_000)
  private let utc = TimeZone(secondsFromGMT: 0)!

  @Test("Main story advances once per local day without health gating")
  func mainStoryDailyGate() async throws {
    let engine = CompanionEventEngine(storage: InMemoryEventLedgerStorage())

    let first = try await engine.completeTodayMainStory(
      at: dayOne,
      timeZone: utc,
      source: .watch,
      eventID: uuid(1)
    )
    let duplicateDay = try await engine.completeTodayMainStory(
      at: dayOne.addingTimeInterval(3_600),
      timeZone: utc,
      source: .watch,
      eventID: uuid(2)
    )
    let second = try await engine.completeTodayMainStory(
      at: dayOne.addingTimeInterval(24 * 3_600),
      timeZone: utc,
      source: .watch,
      eventID: uuid(3)
    )

    guard case .completed(let firstBeat, _) = first else {
      Issue.record("Expected first story beat")
      return
    }
    #expect(firstBeat.beatID == "main.day-1.awakening")
    guard case .alreadyCompletedToday = duplicateDay else {
      Issue.record("Expected same-day idempotence")
      return
    }
    guard case .completed(let secondBeat, let state) = second else {
      Issue.record("Expected second story beat")
      return
    }
    #expect(secondBeat.beatID == "main.day-2.first-step")
    #expect(state.growth.insight == 20)
  }

  @Test("Daily habit settles one optional reward per local day")
  func dailyHabitGate() async throws {
    let engine = CompanionEventEngine(storage: InMemoryEventLedgerStorage())
    let first = try await engine.completeDailyHabit(
      kind: .microRest,
      at: dayOne,
      timeZone: utc,
      source: .watch,
      eventID: uuid(4)
    )
    let repeated = try await engine.completeDailyHabit(
      kind: .shortWalk,
      at: dayOne.addingTimeInterval(60),
      timeZone: utc,
      source: .watch,
      eventID: uuid(5)
    )

    guard case .completed(_, let state) = first else {
      Issue.record("Expected habit completion")
      return
    }
    #expect(state.growth.vitality == 2)
    guard case .alreadyCompletedToday(let repeatedState) = repeated else {
      Issue.record("Expected daily habit gate")
      return
    }
    #expect(repeatedState.growth.vitality == 2)
  }

  @Test("Soccer story is deterministic, explicit, and idempotent")
  func soccerStory() async throws {
    let engine = CompanionEventEngine(storage: InMemoryEventLedgerStorage())
    let workoutID = uuid(6)
    let snapshot = HealthSnapshot(
      capturedAt: dayOne,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      workouts: [
        WorkoutSummary(
          id: workoutID,
          activity: .soccer,
          startedAt: dayOne.addingTimeInterval(-1_800),
          durationMinutes: 30
        )
      ]
    )
    let triggerID = uuid(7)

    let first = try await engine.evaluateSoccerSideStory(
      snapshot: snapshot,
      triggerEventID: triggerID,
      at: dayOne,
      source: .watch,
      probability: 1
    )
    guard case .unlocked(let state) = first else {
      Issue.record("Expected deterministic unlock")
      return
    }
    #expect(state.story.unlockedSideStoryIDs == ["lost_ball"])
    #expect(
      try await engine.evaluateSoccerSideStory(
        snapshot: snapshot,
        triggerEventID: triggerID,
        at: dayOne,
        source: .watch,
        probability: 1
      ) == .alreadyUnlocked
    )
  }

  @Test("A non-soccer workout cannot unlock the soccer story")
  func soccerStoryRejectsInference() async throws {
    let engine = CompanionEventEngine(storage: InMemoryEventLedgerStorage())
    let snapshot = HealthSnapshot(
      capturedAt: dayOne,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      steps: 20_000,
      workouts: [
        WorkoutSummary(
          id: uuid(8),
          activity: .running,
          startedAt: dayOne,
          durationMinutes: 60
        )
      ]
    )

    #expect(
      try await engine.evaluateSoccerSideStory(
        snapshot: snapshot,
        triggerEventID: uuid(9),
        at: dayOne,
        source: .watch,
        probability: 1
      ) == .notEligible
    )
  }

  private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
  }
}
