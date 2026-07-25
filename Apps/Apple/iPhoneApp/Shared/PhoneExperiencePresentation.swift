import AppRuntime
import Foundation
import MoriDomain
import MoriRuntime

nonisolated struct PhoneSceneOption: Identifiable, Equatable, Sendable {
  let id: String
  let title: String

  static let all = CompanionVisualCatalog.backgroundIDs.map {
    PhoneSceneOption(
      id: $0,
      title: CompanionVisualCatalog.backgroundDisplayName($0)
    )
  }
}

nonisolated struct PhoneRecommendedTask: Equatable, Identifiable, Sendable {
  let id: String
  let kind: MoriTaskKind

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
  let completedTaskIDs: Set<String>
  let recommendedTask: PhoneRecommendedTask?

  static let empty = PhoneMockExperienceProjection(
    completedTaskIDs: [],
    recommendedTask: nil
  )

  private init(
    completedTaskIDs: Set<String>,
    recommendedTask: PhoneRecommendedTask?
  ) {
    self.completedTaskIDs = completedTaskIDs
    self.recommendedTask = recommendedTask
  }

  init(
    snapshot: ProductLoopAppSnapshot,
    sensingEnabled: Bool,
    at now: Date = Date()
  ) {
    let state = snapshot.localState
    let today = ProfileQueries.phoneToday(from: state, at: now)
    completedTaskIDs = Set(
      state.tasks.compactMap { task in
        task.lifecycle.isCompleted ? task.header.recordID.rawValue : nil
      }
    )
    recommendedTask =
      sensingEnabled
      ? today.recommended.map {
        PhoneRecommendedTask(
          id: $0.header.recordID.rawValue,
          kind: $0.kind
        )
      }
      : nil
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
