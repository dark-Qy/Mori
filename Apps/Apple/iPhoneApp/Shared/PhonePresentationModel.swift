import Foundation

struct PhonePresentationModel {
  let scenario: PhoneMockScenario
  let level: Int
  let vitality: Int
  let mood: String
  let syncStatus: String
  let metrics: [PhoneMetric]
  let questTitle: String
  let questDetail: String
  let history: [PhoneHistoryDay]
  let activityLog: [PhoneActivityLog]

  static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Self
  {
    let rawScenario =
      arguments
      .first(where: { $0.hasPrefix("--mock-scenario=") })?
      .replacingOccurrences(of: "--mock-scenario=", with: "")
      ?? value(after: "--mock-scenario", in: arguments)

    return make(scenario: PhoneMockScenario(rawValue: rawScenario ?? "") ?? .steadyWeek)
  }

  private static func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
      return nil
    }
    return arguments[index + 1]
  }

  private static func make(scenario: PhoneMockScenario) -> Self {
    switch scenario {
    case .steadyWeek:
      return PhonePresentationModel(
        scenario: scenario,
        level: 7,
        vitality: 76,
        mood: "精神不错，想陪你把今天走稳",
        syncStatus: "刚刚从 Apple Watch 同步",
        metrics: [
          PhoneMetric(
            id: "recovery", title: "恢复", value: "平稳", detail: "接近个人近况", symbol: "moon.stars.fill"),
          PhoneMetric(
            id: "activity", title: "活动", value: "6.2k", detail: "今天的步数", symbol: "figure.walk"),
          PhoneMetric(
            id: "rhythm", title: "节律", value: "更稳", detail: "近 7 日更稳定", symbol: "waveform.path.ecg"),
        ],
        questTitle: "点亮营地的第一盏灯",
        questDetail: "和 Mori 完成今天的故事片段；健康状态不会阻挡主线。",
        history: PhoneHistoryDay.steadyWeek,
        activityLog: PhoneActivityLog.steady
      )
    case .recoveryLow:
      return PhonePresentationModel(
        scenario: scenario,
        level: 7,
        vitality: 58,
        mood: "我会陪你放慢一点，不需要硬撑",
        syncStatus: "刚刚从 Apple Watch 同步",
        metrics: [
          PhoneMetric(
            id: "recovery", title: "恢复", value: "偏低", detail: "比个人近况偏低", symbol: "moon.stars.fill"),
          PhoneMetric(
            id: "activity", title: "活动", value: "3.1k", detail: "今天的步数", symbol: "figure.walk"),
          PhoneMetric(
            id: "rhythm", title: "节律", value: "波动", detail: "最近有所波动", symbol: "waveform.path.ecg"),
        ],
        questTitle: "点亮营地的第一盏灯",
        questDetail: "和 Mori 完成今天的故事片段；健康状态不会阻挡主线。",
        history: PhoneHistoryDay.recoveryLow,
        activityLog: PhoneActivityLog.recovery
      )
    case .activeDay:
      return PhonePresentationModel(
        scenario: scenario,
        level: 8,
        vitality: 88,
        mood: "今天的冒险能量正在发光",
        syncStatus: "刚刚从 Apple Watch 同步",
        metrics: [
          PhoneMetric(
            id: "recovery", title: "恢复", value: "平稳", detail: "接近个人近况", symbol: "moon.stars.fill"),
          PhoneMetric(
            id: "activity", title: "活动", value: "12k", detail: "明显高于平常", symbol: "figure.run"),
          PhoneMetric(
            id: "rhythm", title: "节律", value: "更稳", detail: "近 7 日更稳定", symbol: "waveform.path.ecg"),
        ],
        questTitle: "点亮营地的第一盏灯",
        questDetail: "和 Mori 完成今天的故事片段；健康状态不会阻挡主线。",
        history: PhoneHistoryDay.activeWeek,
        activityLog: PhoneActivityLog.active
      )
    }
  }
}

enum PhoneMockScenario: String {
  case steadyWeek = "steady_week"
  case recoveryLow = "recovery_low"
  case activeDay = "active_day"

  var displayName: String { rawValue }
}

struct PhoneMetric: Identifiable {
  let id: String
  let title: String
  let value: String
  let detail: String
  let symbol: String
}

struct PhoneHistoryDay: Identifiable {
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

  private static func make(recovery: [Double], activity: [Double]) -> [PhoneHistoryDay] {
    let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    return weekdays.indices.map { index in
      PhoneHistoryDay(
        id: index, weekday: weekdays[index], recovery: recovery[index], activity: activity[index])
    }
  }
}

struct PhoneActivityLog: Identifiable {
  let id: String
  let title: String
  let detail: String
  let time: String
  let symbol: String

  static let steady = [
    PhoneActivityLog(
      id: "quest", title: "主线推进", detail: "完成午后轻活动", time: "今天 15:20", symbol: "map.fill"),
    PhoneActivityLog(
      id: "rhythm", title: "节律发现", detail: "连续 3 天在相近时间入睡", time: "今天 08:10", symbol: "sparkles"),
    PhoneActivityLog(
      id: "growth", title: "Mori 成长", detail: "生命力 +12", time: "昨天", symbol: "leaf.fill"),
  ]

  static let recovery = [
    PhoneActivityLog(
      id: "adjust", title: "主线已调轻", detail: "恢复低于近期个人状态", time: "今天 08:12",
      symbol: "slider.horizontal.3"),
    PhoneActivityLog(
      id: "pause", title: "完成休息支线", detail: "10 分钟无屏时间", time: "昨天",
      symbol: "cup.and.heat.waves.fill"),
  ]

  static let active = [
    PhoneActivityLog(
      id: "workout", title: "运动记录", detail: "户外跑步 32 分钟", time: "今天 17:40", symbol: "figure.run"),
    PhoneActivityLog(
      id: "reward", title: "随机支线触发", detail: "获得发光叶子", time: "今天 17:42", symbol: "sparkles"),
  ]
}
