import Domain
import Foundation
import Rules
import Story

public enum CompanionReducerError: Error, Equatable, Sendable {
  case unsupportedEventSchema(Int)
  case unsupportedHealthSnapshotSchema(Int)
  case inconsistentHealthSettlementDay
}

/// Pure event reducer. `reducing` canonicalizes a batch; `reduce` assumes callers supply one event at a time.
public struct CompanionReducer: Sendable {
  public var rules: HealthRuleEngine
  public var habitRules: DailyHabitRuleEngine
  public var story: StoryReducer

  public init(
    rules: HealthRuleEngine = HealthRuleEngine(),
    habitRules: DailyHabitRuleEngine = DailyHabitRuleEngine(),
    story: StoryReducer = StoryReducer()
  ) {
    self.rules = rules
    self.habitRules = habitRules
    self.story = story
  }

  public func replay(
    _ events: [EventEnvelope], from initialState: CompanionState = CompanionState()
  ) throws -> CompanionState {
    try reducing(initialState, events: events)
  }

  public func reducing(_ initialState: CompanionState, events: [EventEnvelope]) throws
    -> CompanionState
  {
    var result = initialState
    for event in events.sorted(by: EventEnvelope.canonicalOrder) {
      try reduce(&result, event: event)
    }
    return result
  }

  public func reduce(_ state: inout CompanionState, event: EventEnvelope) throws {
    guard event.schemaVersion == EventEnvelope.currentSchemaVersion else {
      throw CompanionReducerError.unsupportedEventSchema(event.schemaVersion)
    }
    guard !state.processedEventIDs.contains(event.eventID) else { return }

    switch event.payload {
    case .healthSnapshotReceived(let snapshot):
      guard snapshot.schemaVersion == HealthSnapshot.currentSchemaVersion else {
        throw CompanionReducerError.unsupportedHealthSnapshotSchema(snapshot.schemaVersion)
      }
      guard snapshot.hasConsistentSettlementDay else {
        throw CompanionReducerError.inconsistentHealthSettlementDay
      }
      let decision = rules.evaluate(snapshot, at: event.occurredAt)
      let settlementKey = snapshot.localDay.rawValue
      let settledAward = state.vitalityAwardByDay[settlementKey, default: 0]
      let newAward = max(settledAward, decision.vitalityAward)
      state.growth.vitality += newAward - settledAward
      state.vitalityAwardByDay[settlementKey] = newAward
      state.activeTheme = decision.theme
      state.pet.mood = decision.petMood
      state.lastDecisionTrace = decision.trace

    case .storyBeatCompleted(let completion):
      let previousCount = state.story.completedBeatIDs.count
      state.story = story.completing(completion, in: state.story)
      if state.story.completedBeatIDs.count > previousCount {
        state.growth.insight += 10
      }

    case .sideStoryUnlocked(let unlock):
      state.story = story.unlocking(unlock, in: state.story)

    case .petInteracted:
      state.pet.lastInteractionAt = event.occurredAt
      state.pet.mood = .curious

    case .dailyHabitCompleted(let completion):
      guard
        !state.completedHabitDays.contains(completion.localDay),
        let award = habitRules.vitalityAward(for: completion)
      else { break }
      state.completedHabitDays.insert(completion.localDay)
      state.growth.vitality += award
      state.pet.lastInteractionAt = event.occurredAt
      state.pet.mood = .curious
    }

    state.processedEventIDs.insert(event.eventID)
  }
}
