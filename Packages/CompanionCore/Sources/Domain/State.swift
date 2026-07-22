import Foundation

public enum PetMood: String, Codable, CaseIterable, Sendable {
  case neutral
  case resting
  case curious
  case lively
}

public struct PetState: Codable, Equatable, Sendable {
  public var name: String
  public var mood: PetMood
  public var equippedOutfitID: String?
  public var lastInteractionAt: Date?

  public init(
    name: String = "Mori",
    mood: PetMood = .neutral,
    equippedOutfitID: String? = nil,
    lastInteractionAt: Date? = nil
  ) {
    self.name = name
    self.mood = mood
    self.equippedOutfitID = equippedOutfitID
    self.lastInteractionAt = lastInteractionAt
  }
}

public struct GrowthState: Codable, Equatable, Sendable {
  public var vitality: Int
  public var bond: Int
  public var insight: Int

  public init(vitality: Int = 0, bond: Int = 0, insight: Int = 0) {
    self.vitality = max(0, vitality)
    self.bond = max(0, bond)
    self.insight = max(0, insight)
  }
}

public struct StoryState: Codable, Equatable, Sendable {
  public var mainlineChapter: Int
  public var completedBeatIDs: Set<String>
  public var unlockedSideStoryIDs: Set<String>
  public var memories: [String]

  public init(
    mainlineChapter: Int = 1,
    completedBeatIDs: Set<String> = [],
    unlockedSideStoryIDs: Set<String> = [],
    memories: [String] = []
  ) {
    self.mainlineChapter = max(1, mainlineChapter)
    self.completedBeatIDs = completedBeatIDs
    self.unlockedSideStoryIDs = unlockedSideStoryIDs
    self.memories = memories
  }

  private enum CodingKeys: String, CodingKey {
    case mainlineChapter
    case completedBeatIDs
    case unlockedSideStoryIDs
    case memories
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mainlineChapter = max(1, try container.decode(Int.self, forKey: .mainlineChapter))
    completedBeatIDs = Set(try container.decode([String].self, forKey: .completedBeatIDs))
    unlockedSideStoryIDs = Set(
      try container.decode([String].self, forKey: .unlockedSideStoryIDs)
    )
    memories = try container.decode([String].self, forKey: .memories)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mainlineChapter, forKey: .mainlineChapter)
    try container.encode(completedBeatIDs.sorted(), forKey: .completedBeatIDs)
    try container.encode(unlockedSideStoryIDs.sorted(), forKey: .unlockedSideStoryIDs)
    try container.encode(memories, forKey: .memories)
  }
}

public enum Theme: String, Codable, CaseIterable, Sendable {
  case recovery
  case activity
  case rhythm
  case connection
  case neutral
}

public struct CompanionState: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var pet: PetState
  public var growth: GrowthState
  public var story: StoryState
  public var activeTheme: Theme
  public var lastDecisionTrace: DecisionTrace?
  /// Highest settled vitality award for each normalized local calendar day.
  /// Later snapshots can grant only the positive difference up to the daily cap.
  public var vitalityAwardByDay: [String: Int]
  public var processedEventIDs: Set<UUID>

  public init(
    schemaVersion: Int = CompanionState.currentSchemaVersion,
    pet: PetState = PetState(),
    growth: GrowthState = GrowthState(),
    story: StoryState = StoryState(),
    activeTheme: Theme = .neutral,
    lastDecisionTrace: DecisionTrace? = nil,
    vitalityAwardByDay: [String: Int] = [:],
    processedEventIDs: Set<UUID> = []
  ) {
    self.schemaVersion = schemaVersion
    self.pet = pet
    self.growth = growth
    self.story = story
    self.activeTheme = activeTheme
    self.lastDecisionTrace = lastDecisionTrace
    self.vitalityAwardByDay = vitalityAwardByDay.mapValues { max(0, $0) }
    self.processedEventIDs = processedEventIDs
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case pet
    case growth
    case story
    case activeTheme
    case lastDecisionTrace
    case vitalityAwardByDay
    case processedEventIDs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    pet = try container.decode(PetState.self, forKey: .pet)
    growth = try container.decode(GrowthState.self, forKey: .growth)
    story = try container.decode(StoryState.self, forKey: .story)
    activeTheme = try container.decode(Theme.self, forKey: .activeTheme)
    lastDecisionTrace = try container.decodeIfPresent(
      DecisionTrace.self,
      forKey: .lastDecisionTrace
    )
    vitalityAwardByDay = try container.decode([String: Int].self, forKey: .vitalityAwardByDay)
    processedEventIDs = Set(try container.decode([UUID].self, forKey: .processedEventIDs))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(pet, forKey: .pet)
    try container.encode(growth, forKey: .growth)
    try container.encode(story, forKey: .story)
    try container.encode(activeTheme, forKey: .activeTheme)
    try container.encodeIfPresent(lastDecisionTrace, forKey: .lastDecisionTrace)
    try container.encode(vitalityAwardByDay, forKey: .vitalityAwardByDay)
    try container.encode(
      processedEventIDs.sorted { $0.uuidString < $1.uuidString },
      forKey: .processedEventIDs
    )
  }
}
