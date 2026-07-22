import Foundation
import SwiftUI

struct WatchPresentationModel {
  let scenario: WatchMockScenario
  let level: Int
  let vitality: Int
  let petMood: String
  let petSymbol: String
  let dayStatus: String
  let petPrompt: String
  let metrics: [WatchMetric]
  let quest: WatchQuest
  let trends: [WatchTrendDay]
  let messages: [WatchMessage]

  var unreadMessageCount: Int {
    messages.filter { $0.isUnread }.count
  }

  var trendSummary: String {
    scenario == .recoveryLow ? "恢复需要留意" : "节律正在变稳"
  }

  static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Self
  {
    let rawScenario =
      arguments
      .first(where: { $0.hasPrefix("--mock-scenario=") })?
      .replacingOccurrences(of: "--mock-scenario=", with: "")
      ?? value(after: "--mock-scenario", in: arguments)

    return make(scenario: WatchMockScenario(rawValue: rawScenario ?? "") ?? .steadyWeek)
  }

  private static func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
      return nil
    }
    return arguments[index + 1]
  }

  private static func make(scenario: WatchMockScenario) -> Self {
    switch scenario {
    case .steadyWeek:
      return WatchPresentationModel(
        scenario: scenario,
        level: 7,
        vitality: 76,
        petMood: "精神不错，想陪你把今天走稳",
        petSymbol: "pawprint.fill",
        dayStatus: "状态平稳",
        petPrompt: "你已经专注很久了。要不要起身走两分钟？",
        metrics: [
          WatchMetric(
            id: "recovery", title: "恢复", shortTitle: "恢复", value: "接近个人近况", shortValue: "平稳",
            symbol: "moon.stars.fill", color: AdventurePalette.blue),
          WatchMetric(
            id: "activity", title: "活动", shortTitle: "活动", value: "6,240 步", shortValue: "6.2k",
            symbol: "figure.walk", color: AdventurePalette.mint),
          WatchMetric(
            id: "rhythm", title: "节律", shortTitle: "节律", value: "比近期更稳定", shortValue: "更稳",
            symbol: "waveform.path.ecg", color: AdventurePalette.gold),
        ],
        quest: WatchQuest(
          title: "点亮营地的第一盏灯", detail: "和 Mori 完成今天的故事片段；健康状态不会阻挡主线。", reward: 10,
          progress: 0.5, progressLabel: "1 / 2"),
        trends: WatchTrendDay.steadyWeek,
        messages: WatchMessage.samples
      )
    case .recoveryLow:
      return WatchPresentationModel(
        scenario: scenario,
        level: 7,
        vitality: 58,
        petMood: "我会陪你放慢一点，不需要硬撑",
        petSymbol: "pawprint.fill",
        dayStatus: "适合恢复",
        petPrompt: "昨晚的恢复比你的平常低一些。今天我们少走一步也没关系。",
        metrics: [
          WatchMetric(
            id: "recovery", title: "恢复", shortTitle: "恢复", value: "比个人近况偏低", shortValue: "偏低",
            symbol: "moon.stars.fill", color: AdventurePalette.rose),
          WatchMetric(
            id: "activity", title: "活动", shortTitle: "活动", value: "3,120 步", shortValue: "3.1k",
            symbol: "figure.walk", color: AdventurePalette.mint),
          WatchMetric(
            id: "rhythm", title: "节律", shortTitle: "节律", value: "近期有所波动", shortValue: "波动",
            symbol: "waveform.path.ecg", color: AdventurePalette.gold),
        ],
        quest: WatchQuest(
          title: "点亮营地的第一盏灯", detail: "和 Mori 完成今天的故事片段；健康状态不会阻挡主线。", reward: 10,
          progress: 0.5, progressLabel: "1 / 2"),
        trends: WatchTrendDay.recoveryLow,
        messages: WatchMessage.recoverySamples
      )
    case .activeDay:
      return WatchPresentationModel(
        scenario: scenario,
        level: 8,
        vitality: 88,
        petMood: "今天的冒险能量正在发光",
        petSymbol: "pawprint.fill",
        dayStatus: "活动充沛",
        petPrompt: "刚才那段运动很棒！记得补水，我会帮你守住节奏。",
        metrics: [
          WatchMetric(
            id: "recovery", title: "恢复", shortTitle: "恢复", value: "接近个人近况", shortValue: "平稳",
            symbol: "moon.stars.fill", color: AdventurePalette.blue),
          WatchMetric(
            id: "activity", title: "活动", shortTitle: "活动", value: "12,480 步", shortValue: "12k",
            symbol: "figure.run", color: AdventurePalette.mint),
          WatchMetric(
            id: "rhythm", title: "节律", shortTitle: "节律", value: "比近期更稳定", shortValue: "更稳",
            symbol: "waveform.path.ecg", color: AdventurePalette.gold),
        ],
        quest: WatchQuest(
          title: "点亮营地的第一盏灯", detail: "和 Mori 完成今天的故事片段；健康状态不会阻挡主线。", reward: 10,
          progress: 0.5, progressLabel: "1 / 2"),
        trends: WatchTrendDay.activeWeek,
        messages: WatchMessage.activeSamples
      )
    }
  }
}

enum WatchMockScenario: String {
  case steadyWeek = "steady_week"
  case recoveryLow = "recovery_low"
  case activeDay = "active_day"

  var displayName: String {
    switch self {
    case .steadyWeek: "steady_week"
    case .recoveryLow: "recovery_low"
    case .activeDay: "active_day"
    }
  }
}

struct WatchMetric: Identifiable {
  let id: String
  let title: String
  let shortTitle: String
  let value: String
  let shortValue: String
  let symbol: String
  let color: Color
}

struct WatchQuest {
  let title: String
  let detail: String
  let reward: Int
  let progress: Double
  let progressLabel: String
}

struct WatchTrendDay: Identifiable {
  let id: Int
  let weekday: String
  let recovery: Double
  let activity: Double

  static let steadyWeek = make(
    recovery: [0.62, 0.68, 0.59, 0.74, 0.71, 0.78, 0.76],
    activity: [0.48, 0.72, 0.66, 0.52, 0.78, 0.82, 0.64])
  static let recoveryLow = make(
    recovery: [0.73, 0.68, 0.61, 0.58, 0.54, 0.49, 0.46],
    activity: [0.64, 0.75, 0.70, 0.61, 0.49, 0.46, 0.38])
  static let activeWeek = make(
    recovery: [0.66, 0.72, 0.70, 0.78, 0.75, 0.82, 0.80],
    activity: [0.55, 0.68, 0.74, 0.80, 0.72, 0.88, 0.96])

  private static func make(recovery: [Double], activity: [Double]) -> [WatchTrendDay] {
    let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    return weekdays.indices.map { index in
      WatchTrendDay(
        id: index, weekday: weekdays[index], recovery: recovery[index], activity: activity[index])
    }
  }
}

struct WatchMessage: Identifiable {
  let id: String
  let title: String
  let body: String
  let relativeTime: String
  let symbol: String
  let tint: Color
  let isUnread: Bool

  static let samples = [
    WatchMessage(
      id: "pause", title: "要不要停一下？", body: "你已经坐了很久。走到窗边看看，也算完成一次小冒险。", relativeTime: "刚刚",
      symbol: "cup.and.heat.waves.fill", tint: AdventurePalette.gold, isUnread: true),
    WatchMessage(
      id: "rhythm", title: "我发现一个好节奏", body: "你连续三天在相近时间入睡，Mori 的营地更亮了。", relativeTime: "2 小时前",
      symbol: "sparkles", tint: AdventurePalette.mint, isUnread: true),
    WatchMessage(
      id: "morning", title: "早安，同行者", body: "昨晚恢复接近平常水平，今天不必急着追赶。", relativeTime: "今天 08:10",
      symbol: "sunrise.fill", tint: AdventurePalette.blue, isUnread: false),
  ]

  static let recoverySamples = [
    WatchMessage(
      id: "recover", title: "今天慢一点", body: "恢复低于个人近况，但这不是惩罚。我们把任务缩小一点。", relativeTime: "刚刚",
      symbol: "moon.zzz.fill", tint: AdventurePalette.rose, isUnread: true),
    WatchMessage(
      id: "pause", title: "十分钟也很好", body: "闭眼、呼吸或只是发发呆，都算在照顾自己。", relativeTime: "1 小时前",
      symbol: "leaf.fill", tint: AdventurePalette.mint, isUnread: false),
  ]

  static let activeSamples = [
    WatchMessage(
      id: "move", title: "运动记录到了！", body: "今天活动明显高于平常，Mori 获得了一片发光叶子。", relativeTime: "刚刚",
      symbol: "figure.run", tint: AdventurePalette.mint, isUnread: true),
    WatchMessage(
      id: "water", title: "冒险后补给", body: "活动很多的日子，更要给身体留出补水和舒展时间。", relativeTime: "25 分钟前",
      symbol: "drop.fill", tint: AdventurePalette.blue, isUnread: true),
  ]
}
