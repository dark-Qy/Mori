import AppRuntime
import Foundation
import MoriRuntime

nonisolated enum PhoneCollectionCategory: String, CaseIterable, Identifiable,
  Sendable
{
  case clothing
  case accessories
  case scenes

  var id: String { rawValue }

  var title: String {
    switch self {
    case .clothing: "服装"
    case .accessories: "配饰"
    case .scenes: "场景"
    }
  }
}

nonisolated struct PhoneCollectionItem: Identifiable, Equatable, Sendable {
  let id: String
  let category: PhoneCollectionCategory
  let title: String
  let symbol: String
  let price: Int
  let sceneID: String?

  static let catalog = [
    PhoneCollectionItem(
      id: "default",
      category: .clothing,
      title: "基础外观",
      symbol: "tshirt",
      price: 0,
      sceneID: nil
    ),
    PhoneCollectionItem(
      id: "scarf",
      category: .clothing,
      title: "冒险围巾",
      symbol: "wind",
      price: 8,
      sceneID: nil
    ),
    PhoneCollectionItem(
      id: "soccer_scarf",
      category: .clothing,
      title: "球场围巾",
      symbol: "figure.soccer",
      price: 12,
      sceneID: nil
    ),
    PhoneCollectionItem(
      id: "leaf",
      category: .accessories,
      title: "发光叶子",
      symbol: "leaf.fill",
      price: 4,
      sceneID: nil
    ),
    PhoneCollectionItem(
      id: "star",
      category: .accessories,
      title: "守夜星星",
      symbol: "star.fill",
      price: 8,
      sceneID: nil
    ),
    PhoneCollectionItem(
      id: "spring_meadow_stream",
      category: .scenes,
      title: "春日花溪",
      symbol: "leaf",
      price: 0,
      sceneID: "spring_meadow_stream"
    ),
    PhoneCollectionItem(
      id: "moonlit_forest_camp",
      category: .scenes,
      title: "月光营地",
      symbol: "moon.stars.fill",
      price: 50,
      sceneID: "moonlit_forest_camp"
    ),
  ]
}

nonisolated struct PhoneConversationMessage: Codable, Equatable, Identifiable,
  Sendable
{
  enum Role: String, Codable, Sendable {
    case user
    case mori
  }

  let id: UUID
  let role: Role
  let text: String

  init(id: UUID = UUID(), role: Role, text: String) {
    self.id = id
    self.role = role
    self.text = text
  }
}

nonisolated struct PhoneMockSensingAuthorization: Codable, Equatable, Sendable {
  let enabled: Bool
  let epochCounter: UInt64
  let epochOriginDeviceID: String

  init(_ scope: MoriGlobalSensingScope) {
    enabled = scope.enabled
    epochCounter = scope.epochCounter
    epochOriginDeviceID = scope.epochOriginDeviceID
  }
}

nonisolated struct PhoneMockAppPreferenceState: Equatable, Sendable {
  let proactiveMessagesEnabled: Bool
  let socialSharingEnabled: Bool
  let publicPetSocialStateRawValue: String
}

nonisolated enum PhoneRecommendedTaskKind: String, Codable, Sendable {
  case reflectOnWalk
  case reflectOnSleep
}

nonisolated struct PhoneRecommendedTask: Codable, Equatable, Identifiable,
  Sendable
{
  let id: String
  let scenarioID: String
  let sourceEventID: String
  let cooldownKey: String
  let kind: PhoneRecommendedTaskKind
  let sensingEpochCounter: UInt64
  let sensingEpochOriginDeviceID: String
  let issuedAt: Date
  let cooldownDuration: TimeInterval
  let reward: Int

  var title: String {
    switch kind {
    case .reflectOnWalk:
      "和 Mori 回想今天走过的路"
    case .reflectOnSleep:
      "和 Mori 说说昨晚的休息"
    }
  }

  var detail: String {
    "这段记录来自当前 Mock 事件；系统无法判断你是否完成了回想，所以由你主动确认。"
  }

  var isValid: Bool {
    guard
      id.isEmpty == false,
      scenarioID.isEmpty == false,
      sourceEventID.isEmpty == false,
      cooldownKey.isEmpty == false,
      sensingEpochOriginDeviceID.isEmpty == false,
      reward >= 1,
      cooldownDuration >= 0,
      cooldownDuration.isFinite
    else {
      return false
    }
    return [
      id, scenarioID, sourceEventID, cooldownKey,
      sensingEpochOriginDeviceID,
    ].allSatisfy {
      $0.count <= 160
        && $0.allSatisfy { character in
          character.isASCII
            && (character.isLetter
              || character.isNumber
              || character == "."
              || character == "-"
              || character == "_")
        }
    }
  }
}

nonisolated struct PhoneMockExperienceProjection: Codable, Equatable, Sendable {
  var coinBalance: Int
  var completedTaskIDs: Set<String>
  var ownedItemIDs: Set<String>
  var equippedItemID: String
  var equippedAccessoryID: String?
  var selectedSceneID: String
  var conversation: [PhoneConversationMessage]
  var usesMemoryContext: Bool
  var recommendedTask: PhoneRecommendedTask?
  var generatedTaskSourceEventIDs: Set<String>?
  var taskCooldownUntilByKey: [String: Date]?
  var proactiveMessagesEnabled: Bool?
  var socialSharingEnabled: Bool?
  var publicPetSocialStateRawValue: String?
  var sensingAuthorization: PhoneMockSensingAuthorization?

  static let empty = PhoneMockExperienceProjection(
    coinBalance: 0,
    completedTaskIDs: [],
    ownedItemIDs: [],
    equippedItemID: "default",
    equippedAccessoryID: nil,
    selectedSceneID: "spring_meadow_stream",
    conversation: [],
    usesMemoryContext: false,
    recommendedTask: nil,
    generatedTaskSourceEventIDs: nil,
    taskCooldownUntilByKey: nil,
    proactiveMessagesEnabled: nil,
    socialSharingEnabled: nil,
    publicPetSocialStateRawValue: nil,
    sensingAuthorization: nil
  )

  static let initial = PhoneMockExperienceProjection(
    coinBalance: 18,
    completedTaskIDs: [],
    ownedItemIDs: ["default", "spring_meadow_stream"],
    equippedItemID: "default",
    equippedAccessoryID: nil,
    selectedSceneID: "spring_meadow_stream",
    conversation: [
      PhoneConversationMessage(
        role: .mori,
        text: "我在这里。今天想和我说什么？"
      )
    ],
    usesMemoryContext: false,
    recommendedTask: nil,
    generatedTaskSourceEventIDs: nil,
    taskCooldownUntilByKey: nil,
    proactiveMessagesEnabled: nil,
    socialSharingEnabled: nil,
    publicPetSocialStateRawValue: nil,
    sensingAuthorization: nil
  )

  var appPreferenceState: PhoneMockAppPreferenceState {
    PhoneMockAppPreferenceState(
      proactiveMessagesEnabled: proactiveMessagesEnabled ?? false,
      socialSharingEnabled: socialSharingEnabled ?? false,
      publicPetSocialStateRawValue:
        publicPetSocialStateRawValue ?? PublicPetSocialStateV1.greeting.rawValue
    )
  }

  func isEquipped(_ item: PhoneCollectionItem) -> Bool {
    if let sceneID = item.sceneID {
      return selectedSceneID == sceneID
    }
    switch item.category {
    case .clothing:
      return equippedItemID == item.id
    case .accessories:
      return equippedAccessoryID == item.id
    case .scenes:
      return false
    }
  }
}

struct PhoneMemoryPresentation: Identifiable, Equatable {
  let id: String
  let dayLabel: String
  let sceneID: String
  let narrative: String
  let steps: Int?
  let sleepMinutes: Int?
}

extension PhonePresentationModel {
  func recommendedTaskCandidate(
    sensingScope: MoriGlobalSensingScope?
  ) -> PhoneRecommendedTask? {
    guard
      let sensingScope,
      sensingScope.enabled,
      let scenario = mockScenario
    else {
      return nil
    }
    let eventTime = Int(scenario.evaluatedAt.timeIntervalSince1970)
    let kind: PhoneRecommendedTaskKind
    let eventMetric: String
    let cooldownKey: String
    if let stepCount, stepCount > 0 {
      kind = .reflectOnWalk
      eventMetric = "steps-\(stepCount)"
      cooldownKey = "reflect-walk-summary"
    } else if let sleepMinutes, sleepMinutes > 0 {
      kind = .reflectOnSleep
      eventMetric = "sleep-\(sleepMinutes)"
      cooldownKey = "reflect-sleep-summary"
    } else {
      return nil
    }
    let sourceEventID =
      "mock-event-v1.\(scenario.id).\(eventTime).\(eventMetric)"
    return PhoneRecommendedTask(
      id: "mock-task-v1.\(sourceEventID)",
      scenarioID: scenario.id,
      sourceEventID: sourceEventID,
      cooldownKey: cooldownKey,
      kind: kind,
      sensingEpochCounter: sensingScope.epochCounter,
      sensingEpochOriginDeviceID: sensingScope.epochOriginDeviceID,
      issuedAt: scenario.evaluatedAt,
      cooldownDuration: 6 * 60 * 60,
      reward: 1
    )
  }

  var sharedMemories: [PhoneMemoryPresentation] {
    sealedMemories
  }

  var currentFactNarrative: String {
    if let stepCount {
      return
        "目前本机记录了 \(stepCount.formatted(.number.grouping(.automatic))) 步。"
    }
    if let sleepMinutes {
      let hours = sleepMinutes / 60
      let minutes = sleepMinutes % 60
      let duration = minutes == 0 ? "\(hours)小时" : "\(hours)小时\(minutes)分"
      return "目前本机记录了 \(duration) 的睡眠时长。"
    }
    return "今天还没有可以确认的本机记录。"
  }

  var sleepText: String {
    guard let sleepMinutes else { return "睡眠待记录" }
    let hours = sleepMinutes / 60
    let minutes = sleepMinutes % 60
    return minutes == 0 ? "\(hours)小时" : "\(hours)小时\(minutes)分"
  }

  var stepsText: String {
    guard let stepCount else { return "步数待记录" }
    return "\(stepCount.formatted(.number.grouping(.automatic)))步"
  }
}
