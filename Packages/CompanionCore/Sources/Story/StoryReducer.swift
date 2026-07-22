import Domain
import Foundation

public struct MainStoryBeatDefinition: Equatable, Sendable {
  public var id: String
  public var chapter: Int
  public var prerequisiteBeatID: String?

  public init(id: String, chapter: Int, prerequisiteBeatID: String? = nil) {
    self.id = id
    self.chapter = chapter
    self.prerequisiteBeatID = prerequisiteBeatID
  }
}

public struct SideStoryDefinition: Equatable, Sendable {
  public var id: String
  public var eligibilityRuleID: String
  public var ruleSetVersion: Int

  public init(id: String, eligibilityRuleID: String, ruleSetVersion: Int) {
    self.id = id
    self.eligibilityRuleID = eligibilityRuleID
    self.ruleSetVersion = ruleSetVersion
  }
}

public struct StoryCatalog: Equatable, Sendable {
  public var mainStoryBeats: [MainStoryBeatDefinition]
  public var sideStories: [SideStoryDefinition]

  public init(
    mainStoryBeats: [MainStoryBeatDefinition],
    sideStories: [SideStoryDefinition]
  ) {
    self.mainStoryBeats = mainStoryBeats
    self.sideStories = sideStories
  }

  public static let phaseOne = StoryCatalog(
    mainStoryBeats: [
      MainStoryBeatDefinition(id: "main.day-1.awakening", chapter: 1),
      MainStoryBeatDefinition(
        id: "main.day-2.first-step",
        chapter: 2,
        prerequisiteBeatID: "main.day-1.awakening"
      ),
      MainStoryBeatDefinition(
        id: "main.day-3.weather",
        chapter: 3,
        prerequisiteBeatID: "main.day-2.first-step"
      ),
      MainStoryBeatDefinition(
        id: "main.day-4.shelter",
        chapter: 4,
        prerequisiteBeatID: "main.day-3.weather"
      ),
      MainStoryBeatDefinition(
        id: "main.day-5.signal",
        chapter: 5,
        prerequisiteBeatID: "main.day-4.shelter"
      ),
      MainStoryBeatDefinition(
        id: "main.day-6.map",
        chapter: 6,
        prerequisiteBeatID: "main.day-5.signal"
      ),
      MainStoryBeatDefinition(
        id: "main.day-7.departure",
        chapter: 7,
        prerequisiteBeatID: "main.day-6.map"
      ),
    ],
    sideStories: [
      SideStoryDefinition(
        id: "lost_ball",
        eligibilityRuleID: "phase1.story.soccer-workout",
        ruleSetVersion: 1
      )
    ]
  )
}

public struct StoryReducer: Sendable {
  public var catalog: StoryCatalog

  public init(catalog: StoryCatalog = .phaseOne) {
    self.catalog = catalog
  }

  public func completing(_ completion: StoryBeatCompletion, in state: StoryState) -> StoryState {
    guard
      let definition = catalog.mainStoryBeats.first(where: { $0.id == completion.beatID }),
      definition.chapter == completion.chapter
    else { return state }
    guard !state.completedBeatIDs.contains(completion.beatID) else { return state }
    if let prerequisite = definition.prerequisiteBeatID {
      guard state.completedBeatIDs.contains(prerequisite) else { return state }
    }

    var result = state
    result.completedBeatIDs.insert(completion.beatID)
    result.mainlineChapter = max(result.mainlineChapter, completion.chapter)
    if let memory = completion.memory, !result.memories.contains(memory) {
      result.memories.append(memory)
    }
    return result
  }

  public func unlocking(_ unlock: SideStoryUnlock, in state: StoryState) -> StoryState {
    guard
      let definition = catalog.sideStories.first(where: { $0.id == unlock.storyID }),
      definition.eligibilityRuleID == unlock.ruleID,
      definition.ruleSetVersion == unlock.ruleSetVersion
    else { return state }

    var result = state
    result.unlockedSideStoryIDs.insert(unlock.storyID)
    return result
  }
}

public struct SideStoryCandidate: Equatable, Sendable {
  public var id: String
  public var probability: Double

  public init(id: String, probability: Double) {
    self.id = id
    self.probability = min(max(probability, 0), 1)
  }
}

/// Uses stable candidate ordering so the same seed and eligibility set replay identically.
public struct SideStoryLottery: Sendable {
  public init() {}

  public func draw<R: RandomSource>(
    from candidates: [SideStoryCandidate],
    using randomSource: inout R
  ) -> String? {
    for candidate in candidates.sorted(by: { $0.id < $1.id }) {
      if randomSource.nextUnitInterval() < candidate.probability {
        return candidate.id
      }
    }
    return nil
  }
}
