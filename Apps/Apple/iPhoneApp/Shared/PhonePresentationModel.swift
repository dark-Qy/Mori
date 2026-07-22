import Domain
import Foundation

enum PhoneDataMode: Equatable {
  case live
  case mock(PhoneMockScenario)
  case invalidMock(String)

  static func from(arguments: [String]) -> Self {
    let rawScenario =
      arguments
      .first(where: { $0.hasPrefix("--mock-scenario=") })?
      .replacingOccurrences(of: "--mock-scenario=", with: "")
      ?? value(after: "--mock-scenario", in: arguments)
    guard let rawScenario else { return .live }
    guard let scenario = PhoneMockScenario(rawValue: rawScenario) else {
      return .invalidMock(rawScenario)
    }
    return .mock(scenario)
  }

  private static func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
      return nil
    }
    return arguments[index + 1]
  }
}

struct PhonePresentationModel {
  let dataMode: PhoneDataMode
  let level: Int
  let vitality: Int
  let mood: String
  let syncStatus: String
  let metrics: [PhoneMetric]
  let questTitle: String
  let questDetail: String
  let questProgress: Double
  let history: [PhoneHistoryDay]
  let trendSummary: String
  let activityLog: [PhoneActivityLog]
  let dataExplanation: String

  var mockScenario: PhoneMockScenario? {
    guard case .mock(let scenario) = dataMode else { return nil }
    return scenario
  }

  var isLive: Bool { dataMode == .live }

  static func initial(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
    switch PhoneDataMode.from(arguments: arguments) {
    case .live:
      return liveNoData()
    case .mock(let scenario):
      return mock(scenario: scenario)
    case .invalidMock(let value):
      return invalidMock(value)
    }
  }

  static func live(
    companion: CompanionState,
    health: HealthSnapshot?,
    trend: PersonalHealthTrend?,
    syncStatus: String
  ) -> Self {
    let sleep = health?.sleepMinutes
    let steps = health?.steps
    let rhythmKnown = health?.sleepWindowStart != nil && health?.sleepWindowEnd != nil
    let points = makeHistory(from: trend)
    return PhonePresentationModel(
      dataMode: .live,
      level: max(1, companion.growth.vitality / 100 + 1),
      vitality: min(100, companion.growth.vitality % 100),
      mood: moodText(companion.pet.mood, hasHealth: health?.hasAnyMetric == true),
      syncStatus: syncStatus,
      metrics: [
        PhoneMetric(
          id: "recovery",
          title: "恢复",
          value: sleep.map(sleepText) ?? "--",
          detail: sleep == nil ? "尚无可用睡眠" : "最近一次睡眠",
          symbol: "moon.stars.fill"
        ),
        PhoneMetric(
          id: "activity",
          title: "活动",
          value: steps.map(stepText) ?? "--",
          detail: steps == nil ? "尚无今日步数" : "今日累计步数",
          symbol: "figure.walk"
        ),
        PhoneMetric(
          id: "rhythm",
          title: "节律",
          value: rhythmKnown ? observationText(trend, metric: .sleepTiming) : "--",
          detail: rhythmKnown ? "与个人历史比较" : "需要更多睡眠记录",
          symbol: "waveform.path.ecg"
        ),
      ],
      questTitle: mainStoryTitle(companion.story),
      questDetail: companion.story.completedBeatIDs.count >= 7
        ? "七日主线已完成；可以继续探索日常与随机支线。"
        : "和 Mori 完成今天的故事片段；健康状态不会阻挡主线，每天推进一次。",
      questProgress: min(1, Double(companion.story.completedBeatIDs.count) / 7),
      history: points,
      trendSummary: trendSummary(trend),
      activityLog: liveActivityLog(health: health, companion: companion),
      dataExplanation: health?.hasAnyMetric == true
        ? "来自本机 HealthKit。规则只与个人历史比较；缺失数据不会扣除生命力。"
        : "尚无可用 HealthKit 数据。可能尚未授权，或今天没有对应记录；缺失数据保持中性。"
    )
  }

  static func liveNoData() -> Self {
    live(
      companion: CompanionState(),
      health: nil,
      trend: nil,
      syncStatus: "等待本机数据"
    )
  }

  private static func invalidMock(_ value: String) -> Self {
    let base = liveNoData()
    return PhonePresentationModel(
      dataMode: .invalidMock(value),
      level: base.level,
      vitality: base.vitality,
      mood: "Mock 场景无效，已停止读取真实数据",
      syncStatus: "无效 Mock：\(value)",
      metrics: base.metrics,
      questTitle: base.questTitle,
      questDetail: base.questDetail,
      questProgress: base.questProgress,
      history: [],
      trendSummary: "无演示数据",
      activityLog: [],
      dataExplanation: "Mock 场景名称无效；为避免误读真实 HealthKit，当前保持中性且不访问 Apple 能力。"
    )
  }

  private static func mock(scenario: PhoneMockScenario) -> Self {
    switch scenario {
    case .steadyWeek:
      return PhonePresentationModel(
        dataMode: .mock(scenario),
        level: 7,
        vitality: 76,
        mood: "精神不错，想陪你把今天走稳",
        syncStatus: "Mock：模拟手表同步",
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
        questProgress: 0.62,
        history: PhoneHistoryDay.steadyWeek,
        trendSummary: "节律正在变稳",
        activityLog: PhoneActivityLog.steady,
        dataExplanation: "当前为确定性 Mock 数据。恢复、活动和节律只与个人近期状态比较；缺失数据不会造成惩罚。"
      )
    case .recoveryLow:
      return PhonePresentationModel(
        dataMode: .mock(scenario),
        level: 7,
        vitality: 58,
        mood: "我会陪你放慢一点，不需要硬撑",
        syncStatus: "Mock：模拟手表同步",
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
        questProgress: 0.62,
        history: PhoneHistoryDay.recoveryLow,
        trendSummary: "恢复需要留意",
        activityLog: PhoneActivityLog.recovery,
        dataExplanation: "当前为确定性 Mock 数据。恢复、活动和节律只与个人近期状态比较；缺失数据不会造成惩罚。"
      )
    case .activeDay:
      return PhonePresentationModel(
        dataMode: .mock(scenario),
        level: 8,
        vitality: 88,
        mood: "今天的冒险能量正在发光",
        syncStatus: "Mock：模拟手表同步",
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
        questProgress: 0.8,
        history: PhoneHistoryDay.activeWeek,
        trendSummary: "活动明显高于平常",
        activityLog: PhoneActivityLog.active,
        dataExplanation: "当前为确定性 Mock 数据。恢复、活动和节律只与个人近期状态比较；缺失数据不会造成惩罚。"
      )
    }
  }

  private static func makeHistory(from trend: PersonalHealthTrend?) -> [PhoneHistoryDay] {
    guard let points = trend?.recentDays, !points.isEmpty else { return [] }
    let maxSleep = max(1, points.compactMap(\.sleepMinutes).max() ?? 1)
    let maxSteps = max(1, points.compactMap(\.steps).max() ?? 1)
    return points.enumerated().map { index, point in
      PhoneHistoryDay(
        id: index,
        weekday: String(point.day.rawValue.suffix(2)),
        recovery: point.sleepMinutes.map { Double($0) / Double(maxSleep) },
        activity: point.steps.map { Double($0) / Double(maxSteps) }
      )
    }
  }

  private static func observationText(
    _ trend: PersonalHealthTrend?,
    metric: TrendMetric
  ) -> String {
    guard let observation = trend?.observations.first(where: { $0.metric == metric }) else {
      return "积累中"
    }
    switch observation.status {
    case .belowPersonalRange: return "波动"
    case .withinPersonalRange: return "平稳"
    case .abovePersonalRange: return "更稳"
    case .insufficientData: return "积累中"
    }
  }

  private static func trendSummary(_ trend: PersonalHealthTrend?) -> String {
    guard let trend else { return "需要更多已知天数" }
    let known = trend.usableBaselineDayCount
    guard known >= 2 else { return "已记录 \(known) 天，继续积累个人基线" }
    let sleep = observationText(trend, metric: .sleepDuration)
    let activity = observationText(trend, metric: .steps)
    return "恢复 \(sleep) · 活动 \(activity)"
  }

  private static func moodText(_ mood: PetMood, hasHealth: Bool) -> String {
    guard hasHealth else { return "还没有足够的数据，我会安静陪着你" }
    switch mood {
    case .neutral: return "今天先按自己的节奏来"
    case .resting: return "我会陪你放慢一点，不需要硬撑"
    case .curious: return "我想听听你今天的故事"
    case .lively: return "今天的冒险能量正在发光"
    }
  }

  private static func mainStoryTitle(_ story: StoryState) -> String {
    let titles = [
      "点亮营地的第一盏灯",
      "迈出荒野的第一步",
      "听懂今天的天气",
      "为彼此搭一处庇护",
      "点亮信号塔",
      "画下同行地图",
      "从营地一起启程",
    ]
    let index = min(story.completedBeatIDs.count, titles.count)
    return index == titles.count ? "七日启程已经完成" : titles[index]
  }

  nonisolated private static func sleepText(_ minutes: Int) -> String {
    "\(minutes / 60)h\(minutes % 60)m"
  }

  nonisolated private static func stepText(_ steps: Int) -> String {
    steps >= 1_000 ? String(format: "%.1fk", Double(steps) / 1_000) : String(steps)
  }

  private static func liveActivityLog(
    health: HealthSnapshot?,
    companion: CompanionState
  ) -> [PhoneActivityLog] {
    var result: [PhoneActivityLog] = []
    if let workout = health?.workouts.last {
      result.append(
        PhoneActivityLog(
          id: "workout-\(workout.id.uuidString)",
          title: workout.activity == .soccer ? "足球记录" : "运动记录",
          detail: "持续 \(workout.durationMinutes) 分钟",
          time: "来自 HealthKit",
          symbol: workout.activity == .soccer ? "figure.soccer" : "figure.run"
        )
      )
    }
    if companion.story.unlockedSideStoryIDs.contains("lost_ball") {
      result.append(
        PhoneActivityLog(
          id: "side-story-lost-ball",
          title: "随机支线已出现",
          detail: "失踪的足球：由明确记录的足球训练触发资格",
          time: "规则与固定种子选择",
          symbol: "figure.soccer"
        )
      )
    }
    if let trace = companion.lastDecisionTrace {
      result.append(
        PhoneActivityLog(
          id: "rule-\(trace.evaluatedAt.timeIntervalSince1970)",
          title: "今日状态已更新",
          detail: "使用规则版本 \(trace.ruleSetVersion)；健康状态不会阻挡主线",
          time: "本机计算",
          symbol: "checkmark.shield.fill"
        )
      )
    }
    return result
  }
}

enum PhoneMockScenario: String, Equatable {
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
  let recovery: Double?
  let activity: Double?

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
