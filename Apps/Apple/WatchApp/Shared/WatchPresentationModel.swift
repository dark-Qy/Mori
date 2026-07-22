import Domain
import Foundation
import SwiftUI

enum WatchDataMode: Equatable {
  case live
  case mock(WatchMockScenario)
  case invalidMock(String)

  static func from(arguments: [String]) -> Self {
    let rawScenario =
      arguments
      .first(where: { $0.hasPrefix("--mock-scenario=") })?
      .replacingOccurrences(of: "--mock-scenario=", with: "")
      ?? value(after: "--mock-scenario", in: arguments)
    guard let rawScenario else { return .live }
    guard let scenario = WatchMockScenario(rawValue: rawScenario) else {
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

struct WatchPresentationModel {
  let dataMode: WatchDataMode
  let level: Int
  let vitality: Int
  let petMood: String
  let petSymbol: String
  let outfitID: String?
  let dayStatus: String
  let petPrompt: String
  let actionTitle: String
  let metrics: [WatchMetric]
  let quest: WatchQuest
  let trends: [WatchTrendDay]
  let trendSummary: String
  let trendDetail: String
  let messages: [WatchMessage]
  let dataExplanation: String

  var mockScenario: WatchMockScenario? {
    guard case .mock(let scenario) = dataMode else { return nil }
    return scenario
  }

  var isLive: Bool { dataMode == .live }
  var unreadMessageCount: Int { messages.filter(\.isUnread).count }

  static func initial(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
    switch WatchDataMode.from(arguments: arguments) {
    case .live: liveNoData()
    case .mock(let scenario): mock(scenario: scenario)
    case .invalidMock(let value): invalidMock(value)
    }
  }

  static func live(
    companion: CompanionState,
    health: HealthSnapshot?,
    trend: PersonalHealthTrend?,
    peerValues: [String: String]? = nil
  ) -> Self {
    // Health and growth remain Watch-local. Phone sync is currently authoritative only for
    // management settings such as cosmetics, so delayed peer state cannot override fresh rules.
    let vitality = companion.growth.vitality
    let hasHealth = health?.hasAnyMetric == true
    let trends = makeTrends(from: trend)
    return WatchPresentationModel(
      dataMode: .live,
      level: max(1, vitality / 100 + 1),
      vitality: min(100, vitality % 100),
      petMood: moodText(companion.pet.mood, hasHealth: hasHealth),
      petSymbol: "pawprint.fill",
      outfitID: peerValues?["outfit"] ?? companion.pet.equippedOutfitID,
      dayStatus: statusText(companion.activeTheme, hasHealth: hasHealth),
      petPrompt: promptText(companion.activeTheme, hasHealth: hasHealth),
      actionTitle: actionTitle(companion.activeTheme, hasHealth: hasHealth),
      metrics: [
        WatchMetric(
          id: "recovery",
          title: "恢复",
          shortTitle: "恢复",
          value: health?.sleepMinutes.map { "睡眠 \($0 / 60) 小时 \($0 % 60) 分" } ?? "尚无可用睡眠",
          shortValue: health?.sleepMinutes.map { "\($0 / 60)h\($0 % 60)m" } ?? "--",
          symbol: "moon.stars.fill",
          color: AdventurePalette.blue
        ),
        WatchMetric(
          id: "activity",
          title: "活动",
          shortTitle: "活动",
          value: health?.steps.map { "\($0) 步" } ?? "尚无今日步数",
          shortValue: health?.steps.map { shortSteps($0) } ?? "--",
          symbol: "figure.walk",
          color: AdventurePalette.mint
        ),
        WatchMetric(
          id: "rhythm",
          title: "节律",
          shortTitle: "节律",
          value: health?.sleepWindowStart == nil ? "需要更多睡眠记录" : trendDetail(trend),
          shortValue: health?.sleepWindowStart == nil
            ? "--" : observationText(trend, metric: .sleepTiming),
          symbol: "waveform.path.ecg",
          color: AdventurePalette.gold
        ),
      ],
      quest: WatchQuest(
        title: mainStoryTitle(companion.story),
        detail: mainStoryDetail(companion.story),
        reward: 10,
        progress: min(1, Double(companion.story.completedBeatIDs.count) / 7),
        progressLabel: "\(companion.story.completedBeatIDs.count) / 7",
        sideStoryTitle: companion.story.unlockedSideStoryIDs.contains("lost_ball")
          ? "随机支线：失踪的足球" : nil
      ),
      trends: trends,
      trendSummary: trendSummary(trend),
      trendDetail: trendDetail(trend),
      messages: liveMessages(theme: companion.activeTheme, hasHealth: hasHealth),
      dataExplanation: hasHealth
        ? "来自本机 HealthKit；规则只与个人历史比较，缺失数据不会扣除生命力。"
        : "尚无可用 HealthKit 数据。可能尚未授权或今天没有记录；缺失数据保持中性。"
    )
  }

  static func liveNoData() -> Self {
    live(companion: CompanionState(), health: nil, trend: nil)
  }

  private static func invalidMock(_ value: String) -> Self {
    let base = liveNoData()
    return WatchPresentationModel(
      dataMode: .invalidMock(value),
      level: base.level,
      vitality: base.vitality,
      petMood: "Mock 场景无效，已停止读取真实数据",
      petSymbol: base.petSymbol,
      outfitID: nil,
      dayStatus: "Mock 无效",
      petPrompt: "请修正启动参数；当前不会访问 HealthKit。",
      actionTitle: "不可用",
      metrics: base.metrics,
      quest: base.quest,
      trends: [],
      trendSummary: "无演示数据",
      trendDetail: "Mock 场景名称无效。",
      messages: [],
      dataExplanation: "为避免测试参数拼错后读取真实数据，当前保持中性且不访问 Apple 能力。"
    )
  }

  private static func mock(scenario: WatchMockScenario) -> Self {
    switch scenario {
    case .steadyWeek:
      return WatchPresentationModel(
        dataMode: .mock(scenario),
        level: 7,
        vitality: 76,
        petMood: "精神不错，想陪你把今天走稳",
        petSymbol: "pawprint.fill",
        outfitID: "leaf",
        dayStatus: "状态平稳",
        petPrompt: "你已经专注很久了。要不要起身走两分钟？",
        actionTitle: "一起走两分钟",
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
        trendSummary: "节律正在变稳",
        trendDetail: "近 7 天入睡时间更稳定，节律比上周更连贯。",
        messages: WatchMessage.samples,
        dataExplanation: "当前页面使用显式确定性 Mock 数据，不代表医疗建议。"
      )
    case .recoveryLow:
      return WatchPresentationModel(
        dataMode: .mock(scenario),
        level: 7,
        vitality: 58,
        petMood: "我会陪你放慢一点，不需要硬撑",
        petSymbol: "pawprint.fill",
        outfitID: "scarf",
        dayStatus: "适合恢复",
        petPrompt: "昨晚的恢复比你的平常低一些。今天我们少走一步也没关系。",
        actionTitle: "留十分钟休息",
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
        trendSummary: "恢复需要留意",
        trendDetail: "最近恢复连续走低，今天的主线仍然开放，并建议减轻支线。",
        messages: WatchMessage.recoverySamples,
        dataExplanation: "当前页面使用显式确定性 Mock 数据，不代表医疗建议。"
      )
    case .activeDay:
      return WatchPresentationModel(
        dataMode: .mock(scenario),
        level: 8,
        vitality: 88,
        petMood: "今天的冒险能量正在发光",
        petSymbol: "pawprint.fill",
        outfitID: "star",
        dayStatus: "活动充沛",
        petPrompt: "刚才那段运动很棒！记得补水，我会帮你守住节奏。",
        actionTitle: "回应 Mori",
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
        trendSummary: "活动明显高于平常",
        trendDetail: "今天活动很多，完成冒险后记得补水并留出恢复时间。",
        messages: WatchMessage.activeSamples,
        dataExplanation: "当前页面使用显式确定性 Mock 数据，不代表医疗建议。"
      )
    }
  }

  private static func makeTrends(from trend: PersonalHealthTrend?) -> [WatchTrendDay] {
    guard let points = trend?.recentDays, !points.isEmpty else { return [] }
    let maxSleep = max(1, points.compactMap(\.sleepMinutes).max() ?? 1)
    let maxSteps = max(1, points.compactMap(\.steps).max() ?? 1)
    return points.enumerated().map { index, point in
      WatchTrendDay(
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
    guard observation.status != .insufficientData else { return "积累中" }
    return switch metric {
    case .sleepDuration:
      switch observation.status {
      case .belowPersonalRange: "少于近期"
      case .withinPersonalRange: "接近近期"
      case .abovePersonalRange: "多于近期"
      case .insufficientData: "积累中"
      }
    case .steps, .activeMinutes:
      switch observation.status {
      case .belowPersonalRange: "低于近期"
      case .withinPersonalRange: "接近近期"
      case .abovePersonalRange: "高于近期"
      case .insufficientData: "积累中"
      }
    case .sleepTiming:
      switch observation.status {
      case .belowPersonalRange: "波动增加"
      case .withinPersonalRange: "接近近期"
      case .abovePersonalRange: "更稳定"
      case .insufficientData: "积累中"
      }
    }
  }

  private static func trendSummary(_ trend: PersonalHealthTrend?) -> String {
    guard let trend else { return "需要更多已知天数" }
    return trend.usableBaselineDayCount < 2
      ? "已记录 \(trend.usableBaselineDayCount) 天"
      : "恢复 \(observationText(trend, metric: .sleepDuration)) · 活动 \(observationText(trend, metric: .steps))"
  }

  private static func trendDetail(_ trend: PersonalHealthTrend?) -> String {
    guard let trend, trend.usableBaselineDayCount >= 7 else {
      return "个人基线至少需要 7 个已知日；缺失日不会按零计算。"
    }
    return "最近 7 个已知日与最多 30 天个人历史比较，不与其他人比较。"
  }

  private static func moodText(_ mood: PetMood, hasHealth: Bool) -> String {
    guard hasHealth else { return "还没有足够的数据，我会安静陪着你" }
    return switch mood {
    case .neutral: "今天先按自己的节奏来"
    case .resting: "我会陪你放慢一点，不需要硬撑"
    case .curious: "我想听听你今天的故事"
    case .lively: "今天的冒险能量正在发光"
    }
  }

  private static func statusText(_ theme: Theme, hasHealth: Bool) -> String {
    guard hasHealth else { return "等待数据" }
    return switch theme {
    case .recovery: "适合恢复"
    case .activity: "关注活动"
    case .rhythm: "关注节律"
    case .connection: "适合连接"
    case .neutral: "状态平稳"
    }
  }

  private static func promptText(_ theme: Theme, hasHealth: Bool) -> String {
    guard hasHealth else { return "连接健康数据后，我会用你的个人趋势陪你安排节奏。" }
    return switch theme {
    case .recovery: "今天可以慢一点。要不要留十分钟给自己？"
    case .activity: "如果你愿意，我们可以一起走两分钟。"
    case .rhythm: "今天也试试守住一个舒服的收尾时间。"
    case .connection: "要不要和同行者分享一段不含原始数据的关心摘要？"
    case .neutral: "今天先按自己的节奏来，我会在这里。"
    }
  }

  private static func actionTitle(_ theme: Theme, hasHealth: Bool) -> String {
    guard hasHealth else { return "回应 Mori" }
    return switch theme {
    case .recovery: "留十分钟休息"
    case .activity: "一起走两分钟"
    case .rhythm: "开始今晚收尾"
    case .connection, .neutral: "回应 Mori"
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

  private static func mainStoryDetail(_ story: StoryState) -> String {
    story.completedBeatIDs.count >= 7
      ? "主线的关键章节已完成；接下来可以自由探索支线。"
      : "完成今天的故事片段；健康状态不会阻挡主线，每天推进一次。"
  }

  nonisolated private static func shortSteps(_ steps: Int) -> String {
    steps >= 1_000 ? String(format: "%.1fk", Double(steps) / 1_000) : String(steps)
  }

  private static func liveMessages(theme: Theme, hasHealth: Bool) -> [WatchMessage] {
    guard hasHealth else { return [] }
    switch theme {
    case .recovery:
      return [
        WatchMessage(
          id: "live-recovery", title: "今天可以慢一点", body: "要不要留十分钟给自己？不完成也不会失去什么。",
          relativeTime: "待回应", symbol: "moon.zzz.fill", tint: AdventurePalette.rose, isUnread: true
        )
      ]
    case .activity:
      return [
        WatchMessage(
          id: "live-activity", title: "一起动一小会儿？", body: "如果你愿意，我们可以一起走两分钟。",
          relativeTime: "待回应", symbol: "figure.walk", tint: AdventurePalette.mint, isUnread: true
        )
      ]
    case .rhythm, .connection, .neutral:
      return []
    }
  }
}

enum WatchMockScenario: String, Equatable {
  case steadyWeek = "steady_week"
  case recoveryLow = "recovery_low"
  case activeDay = "active_day"

  var displayName: String { rawValue }
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
  var sideStoryTitle: String? = nil
}

struct WatchTrendDay: Identifiable {
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
      id: "recover", title: "今天慢一点", body: "恢复低于个人近况，但这不是惩罚。我们把支线缩小一点。", relativeTime: "刚刚",
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
