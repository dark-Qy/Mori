import Foundation
import MoriRuntime

enum WatchProductRoute: String, Hashable {
  case today
  case letters
  case touchExchange
  case settings
  case companionSettings
  case dailyMemory
}

extension CompanionReminderMode {
  var title: String {
    switch self {
    case .wristRaise: "抬腕提醒"
    case .gentleHaptic: "轻震提醒"
    }
  }

  var detail: String {
    switch self {
    case .wristRaise: "不震动，下次抬腕时显示"
    case .gentleHaptic: "新事件出现时轻震一次"
    }
  }
}

struct WatchGlancePresentation: Equatable, Identifiable {
  let id: String
  let message: String
  let reaction: WatchCharacterAnimation
  let shouldPlayHaptic: Bool
}

extension WatchPresentationModel {
  var sleepMinutes: Int? {
    metrics.first(where: { $0.id == "recovery" })?.numericValue
  }

  var stepCount: Int? {
    metrics.first(where: { $0.id == "activity" })?.numericValue
  }

  var homeSleepText: String {
    guard let sleepMinutes else { return "睡眠待记录" }
    let hours = sleepMinutes / 60
    let minutes = sleepMinutes % 60
    return minutes == 0 ? "\(hours)小时" : "\(hours)小时\(minutes)分"
  }

  var homeStepsText: String {
    guard let stepCount else { return "步数待记录" }
    return "\(stepCount.formatted(.number.grouping(.automatic)))步"
  }

  var sharedMemoryNarrative: String {
    guard let stepCount else { return "今天的共同记录还在等待同步。" }
    return
      "今天，我们一起记录了 \(stepCount.formatted(.number.grouping(.automatic))) 步。"
  }

  var sharedMemoryDetail: String {
    guard sleepMinutes != nil else {
      return "没有更多经过确认的内容时，Mori 会保持安静。"
    }
    return "昨晚的睡眠记录是 \(homeSleepText)。"
  }

}
