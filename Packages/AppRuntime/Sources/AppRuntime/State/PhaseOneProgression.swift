import Domain
import Foundation
import Persistence
import Rules
import Story

public enum DailyMainStoryOutcome: Equatable, Sendable {
  case completed(StoryBeatCompletion, CompanionState)
  case alreadyCompletedToday(CompanionState)
  case storyComplete(CompanionState)

  public var state: CompanionState {
    switch self {
    case .completed(_, let state), .alreadyCompletedToday(let state), .storyComplete(let state):
      state
    }
  }
}

public enum DailyHabitOutcome: Equatable, Sendable {
  case completed(DailyHabitCompletion, CompanionState)
  case alreadyCompletedToday(CompanionState)

  public var state: CompanionState {
    switch self {
    case .completed(_, let state), .alreadyCompletedToday(let state): state
    }
  }
}

public enum SoccerSideStoryOutcome: Equatable, Sendable {
  case notEligible
  case notSelected
  case alreadyUnlocked
  case unlocked(CompanionState)
}

extension CompanionEventEngine {
  public func completeTodayMainStory(
    at date: Date,
    timeZone: TimeZone,
    source: EventSource,
    eventID: UUID = UUID(),
    catalog: StoryCatalog = .phaseOne
  ) async throws -> DailyMainStoryOutcome {
    let state = try await currentState()
    let today = LocalDay.containing(date, in: timeZone)
    let alreadyCompleted = try await currentEvents().contains { event in
      guard case .storyBeatCompleted = event.payload else { return false }
      return LocalDay.containing(event.occurredAt, in: timeZone) == today
    }
    guard !alreadyCompleted else { return .alreadyCompletedToday(state) }

    guard
      let next = catalog.mainStoryBeats.first(where: { definition in
        !state.story.completedBeatIDs.contains(definition.id)
          && (definition.prerequisiteBeatID.map(state.story.completedBeatIDs.contains) ?? true)
      })
    else { return .storyComplete(state) }

    let completion = StoryBeatCompletion(beatID: next.id, chapter: next.chapter)
    let updated = try await append(
      EventEnvelope(
        eventID: eventID,
        occurredAt: date,
        source: source,
        payload: .storyBeatCompleted(completion)
      )
    )
    return .completed(completion, updated)
  }

  public func completeDailyHabit(
    kind: DailyHabitKind,
    at date: Date,
    timeZone: TimeZone,
    source: EventSource,
    eventID: UUID = UUID()
  ) async throws -> DailyHabitOutcome {
    let state = try await currentState()
    let today = LocalDay.containing(date, in: timeZone)
    guard !state.completedHabitDays.contains(today) else {
      return .alreadyCompletedToday(state)
    }
    let completion = DailyHabitCompletion(kind: kind, localDay: today)
    let updated = try await append(
      EventEnvelope(
        eventID: eventID,
        occurredAt: date,
        source: source,
        payload: .dailyHabitCompleted(completion)
      )
    )
    return .completed(completion, updated)
  }

  public func evaluateSoccerSideStory(
    snapshot: HealthSnapshot,
    triggerEventID: UUID,
    at date: Date,
    source: EventSource,
    probability: Double = 0.45
  ) async throws -> SoccerSideStoryOutcome {
    let state = try await currentState()
    guard !state.story.unlockedSideStoryIDs.contains("lost_ball") else {
      return .alreadyUnlocked
    }
    guard let workout = SoccerSideStoryRule().qualifyingWorkout(in: snapshot) else {
      return .notEligible
    }

    var random = RuntimeSeededRandomSource(
      seed: StableRuntimeIdentity.seed(
        "\(workout.id.uuidString)|\(snapshot.localDay.rawValue)|lost_ball"
      )
    )
    let selected = SideStoryLottery().draw(
      from: [SideStoryCandidate(id: "lost_ball", probability: probability)],
      using: &random
    )
    guard selected == "lost_ball" else { return .notSelected }

    let updated = try await append(
      EventEnvelope(
        eventID: StableRuntimeIdentity.uuid(
          "\(triggerEventID.uuidString)|\(workout.id.uuidString)|lost_ball"
        ),
        occurredAt: date,
        source: source,
        payload: .sideStoryUnlocked(
          SideStoryUnlock(
            storyID: "lost_ball",
            ruleID: SoccerSideStoryRule.ruleID,
            ruleSetVersion: SoccerSideStoryRule.ruleSetVersion,
            triggerEventID: triggerEventID
          )
        )
      )
    )
    return .unlocked(updated)
  }
}

private struct RuntimeSeededRandomSource: RandomSource {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func nextUnitInterval() -> Double {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    value ^= value >> 31
    return Double(value >> 11) / 9_007_199_254_740_992.0
  }
}

private enum StableRuntimeIdentity {
  static func seed(_ descriptor: String) -> UInt64 {
    descriptor.utf8.reduce(0xCBF2_9CE4_8422_2325) { hash, byte in
      (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
  }

  static func uuid(_ descriptor: String) -> UUID {
    let first = seed(descriptor)
    let second = descriptor.utf8.reversed().reduce(0x8422_2325_CBF2_9CE4) { hash, byte in
      (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
    return UUID(
      uuid: (
        UInt8(truncatingIfNeeded: first >> 56), UInt8(truncatingIfNeeded: first >> 48),
        UInt8(truncatingIfNeeded: first >> 40), UInt8(truncatingIfNeeded: first >> 32),
        UInt8(truncatingIfNeeded: first >> 24), UInt8(truncatingIfNeeded: first >> 16),
        UInt8(truncatingIfNeeded: first >> 8), UInt8(truncatingIfNeeded: first),
        UInt8(truncatingIfNeeded: second >> 56), UInt8(truncatingIfNeeded: second >> 48),
        UInt8(truncatingIfNeeded: second >> 40), UInt8(truncatingIfNeeded: second >> 32),
        UInt8(truncatingIfNeeded: second >> 24), UInt8(truncatingIfNeeded: second >> 16),
        UInt8(truncatingIfNeeded: second >> 8), UInt8(truncatingIfNeeded: second)
      )
    )
  }
}
