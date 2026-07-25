import AppRuntime
import Foundation
import MoriDomain
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

nonisolated struct PhoneRecommendedTask: Equatable, Identifiable, Sendable {
  let id: String
  let kind: MoriTaskKind
  let reward: Int

  var title: String {
    switch kind {
    case .walkTogether:
      "和 Mori 一起走一小段"
    case .pauseTogether:
      "和 Mori 一起停下来歇一会儿"
    case .bedtimeWindDown:
      "和 Mori 一起准备休息"
    case .hydrate:
      "陪 Mori 喝点水"
    case .mindfulPause:
      "和 Mori 安静地待一会儿"
    case .exploreNearby:
      "和 Mori 看看附近"
    case .reflectOnDay:
      "和 Mori 回想今天走过的路"
    }
  }

  var detail: String {
    "这件事无法由设备可靠判断，所以由你主动确认；确认后只结算一次。"
  }
}

nonisolated struct PhoneMockExperienceProjection: Equatable, Sendable {
  let coinBalance: Int
  let completedTaskIDs: Set<String>
  let ownedItemIDs: Set<String>
  let equippedItemID: String
  let equippedAccessoryID: String?
  let selectedSceneID: String
  let recommendedTask: PhoneRecommendedTask?

  static let empty = PhoneMockExperienceProjection(
    coinBalance: 0,
    completedTaskIDs: [],
    ownedItemIDs: [],
    equippedItemID: "default",
    equippedAccessoryID: nil,
    selectedSceneID: "spring_meadow_stream",
    recommendedTask: nil
  )

  private init(
    coinBalance: Int,
    completedTaskIDs: Set<String>,
    ownedItemIDs: Set<String>,
    equippedItemID: String,
    equippedAccessoryID: String?,
    selectedSceneID: String,
    recommendedTask: PhoneRecommendedTask?
  ) {
    self.coinBalance = coinBalance
    self.completedTaskIDs = completedTaskIDs
    self.ownedItemIDs = ownedItemIDs
    self.equippedItemID = equippedItemID
    self.equippedAccessoryID = equippedAccessoryID
    self.selectedSceneID = selectedSceneID
    self.recommendedTask = recommendedTask
  }

  init(
    snapshot: ProductLoopAppSnapshot,
    sensingEnabled: Bool,
    at now: Date = Date()
  ) {
    let state = snapshot.localState
    let today = ProfileQueries.phoneToday(from: state, at: now)
    coinBalance = state.coinLedger.balance
    completedTaskIDs = Set(
      state.tasks.compactMap { task in
        task.lifecycle.isCompleted ? task.header.recordID.rawValue : nil
      }
    )
    ownedItemIDs = Set(
      state.collection.ownership.map(\.cosmeticID.rawValue)
    )
    equippedItemID =
      state.collection.equipped[.outfit]?.cosmeticID.rawValue ?? "default"
    equippedAccessoryID =
      state.collection.equipped[.accessory]?.cosmeticID.rawValue
    selectedSceneID =
      state.collection.equipped[.scene]?.cosmeticID.rawValue
      ?? "spring_meadow_stream"
    recommendedTask =
      sensingEnabled
      ? today.recommended.map {
        PhoneRecommendedTask(
          id: $0.header.recordID.rawValue,
          kind: $0.kind,
          reward: $0.rewardTier.rawValue
        )
      }
      : nil
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
