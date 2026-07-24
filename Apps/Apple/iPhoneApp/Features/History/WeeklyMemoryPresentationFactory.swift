import CryptoKit
import Domain
import Foundation

struct WeeklyMemoryPresentationFactory {
  static let timelineDayCount = 35
  static let daysPerWeek = 7

  func makeTimeline(model: PhonePresentationModel) -> [ArchivedWeeklyMemory] {
    guard
      let scenario = model.mockScenario,
      scenario.id.hasPrefix("mock7_"),
      scenario.healthSnapshots.count >= Self.daysPerWeek,
      let timeZone = TimeZone(identifier: scenario.timeZoneIdentifier)
    else { return [] }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let anchor = calendar.startOfDay(for: scenario.now)
    guard
      let timelineEndExclusive = calendar.date(byAdding: .day, value: 1, to: anchor),
      let timelineStart = calendar.date(
        byAdding: .day,
        value: -Self.timelineDayCount,
        to: timelineEndExclusive
      )
    else { return [] }

    return (0..<(Self.timelineDayCount / Self.daysPerWeek)).compactMap { index in
      guard
        let start = calendar.date(
          byAdding: .day,
          value: index * Self.daysPerWeek,
          to: timelineStart
        ),
        let endExclusive = calendar.date(
          byAdding: .day,
          value: Self.daysPerWeek,
          to: start
        ),
        let end = calendar.date(byAdding: .day, value: -1, to: endExclusive)
      else { return nil }

      let startKey = dateKey(start, timeZone: timeZone)
      let endExclusiveKey = dateKey(endExclusive, timeZone: timeZone)
      let days = scenario.healthSnapshots
        .filter {
          $0.localDay.rawValue >= startKey
            && $0.localDay.rawValue < endExclusiveKey
        }
        .sorted { $0.localDay < $1.localDay }
      guard !days.isEmpty else { return nil }

      return makeWeek(
        scenarioID: scenario.id,
        weekOrdinal: index + 1,
        start: start,
        end: end,
        days: days,
        timeZone: timeZone
      )
    }
  }

  private func makeWeek(
    scenarioID: String,
    weekOrdinal: Int,
    start: Date,
    end: Date,
    days: [HealthSnapshot],
    timeZone: TimeZone
  ) -> ArchivedWeeklyMemory {
    let featuredWorkout =
      days
      .flatMap(\.workouts)
      .filter { $0.activity != .other }
      .max { lhs, rhs in lhs.durationMinutes < rhs.durationMinutes }
    let averageSteps = average(days.compactMap(\.steps))
    let averageSleep = average(days.compactMap(\.sleepMinutes))
    let moment = moment(
      scenarioID: scenarioID,
      averageSteps: averageSteps,
      averageSleep: averageSleep,
      featuredWorkout: featuredWorkout
    )
    let metrics = metrics(for: days)
    let totalSteps = completeTotal(days.compactMap(\.steps), expectedCount: days.count)
    let totalActiveMinutes = completeTotal(
      days.compactMap(\.activeMinutes),
      expectedCount: days.count
    )
    let averageSleepMinutes = completeAverage(
      days.compactMap(\.sleepMinutes),
      expectedCount: days.count
    )
    let sleepRoutine = WeeklySleepRoutineAggregate.make(snapshots: days)
    let startKey = dateKey(start, timeZone: timeZone)
    let endKey = dateKey(end, timeZone: timeZone)
    let weekID = "\(scenarioID)-\(startKey)-\(endKey)"
    let sourceHashInput = [
      weekID,
      days.map(daySourceKey).joined(separator: "|"),
      moment.coverAssetName,
      moment.highlight.title,
      metrics.map { "\($0.id):\($0.value)" }.joined(separator: "|"),
      sleepRoutine.map {
        "\($0.band.rawValue):\($0.regularity.rawValue):\($0.sampleCount)"
      } ?? "sleep-routine:nil",
    ].joined(separator: "::")
    let metricsDescription =
      metrics
      .map { "\($0.label)\($0.accessibilityValue)" }
      .joined(separator: "，")

    return ArchivedWeeklyMemory(
      weekID: weekID,
      sourceHash: hash(sourceHashInput),
      weekOrdinal: weekOrdinal,
      weekLabel: weekOrdinal == 5 ? "最近一周" : "第 \(weekOrdinal) 周",
      dateLabel: "\(shortDate(start, timeZone: timeZone))—\(shortDate(end, timeZone: timeZone))",
      title: moment.title,
      body: moment.body,
      metrics: metrics,
      highlight: moment.highlight,
      facts: WeeklyMemoryFacts(
        startDate: startKey,
        endDate: endKey,
        activityKind: featuredWorkout.map { activityKind($0.activity) },
        activityDurationMinutes: featuredWorkout?.durationMinutes,
        totalSteps: totalSteps,
        activeMinutes: totalActiveMinutes,
        averageSleepMinutes: averageSleepMinutes,
        sleepRoutine: sleepRoutine
      ),
      polishContextHash: nil,
      bundledCoverAssetName: moment.coverAssetName,
      source: .mock,
      isFavorite: false,
      isHidden: false,
      createdAt: end,
      accessibilityDescription:
        "\(moment.title)。\(moment.body)\(metricsDescription.isEmpty ? "" : " \(metricsDescription)。")"
    )
  }

  private func metrics(for days: [HealthSnapshot]) -> [WeeklyMemoryMetric] {
    var result: [WeeklyMemoryMetric] = []

    let steps = days.compactMap(\.steps)
    if days.count == Self.daysPerWeek, steps.count == days.count {
      let total = steps.reduce(0, +)
      let text = "\(number(total)) 步"
      result.append(
        WeeklyMemoryMetric(
          id: "steps",
          label: "本周步数",
          value: text,
          accessibilityValue: text,
          symbol: "figure.walk"
        )
      )
    }

    let activeMinutes = days.compactMap(\.activeMinutes)
    if days.count == Self.daysPerWeek, activeMinutes.count == days.count {
      let total = activeMinutes.reduce(0, +)
      let text = "\(number(total)) 分钟"
      result.append(
        WeeklyMemoryMetric(
          id: "active",
          label: "活动时间",
          value: text,
          accessibilityValue: text,
          symbol: "figure.run"
        )
      )
    }

    let sleepMinutes = days.compactMap(\.sleepMinutes)
    if days.count == Self.daysPerWeek, sleepMinutes.count == days.count,
      let averageSleep = average(sleepMinutes)
    {
      let rounded = Int(averageSleep.rounded())
      result.append(
        WeeklyMemoryMetric(
          id: "sleep",
          label: "平均睡眠",
          value: duration(rounded),
          accessibilityValue: "\(rounded / 60) 小时 \(rounded % 60) 分钟",
          symbol: "moon.stars.fill"
        )
      )
    }

    return result
  }

  private func completeTotal(_ values: [Int], expectedCount: Int) -> Int? {
    guard expectedCount == Self.daysPerWeek, values.count == expectedCount else { return nil }
    return values.reduce(0, +)
  }

  private func completeAverage(_ values: [Int], expectedCount: Int) -> Int? {
    guard
      expectedCount == Self.daysPerWeek,
      values.count == expectedCount,
      let value = average(values)
    else { return nil }
    return Int(value.rounded())
  }

  private func activityKind(_ activity: WorkoutSummary.Activity) -> String {
    switch activity {
    case .walking: "walking"
    case .swimming: "swimming"
    case .badminton: "badminton"
    case .tennis: "tennis"
    case .soccer: "football"
    case .running: "running"
    case .cycling: "cycling"
    case .other: "other"
    }
  }

  private func moment(
    scenarioID: String,
    averageSteps: Double?,
    averageSleep: Double?,
    featuredWorkout: WorkoutSummary?
  ) -> (
    title: String,
    body: String,
    highlight: WeeklyMemoryHighlight,
    coverAssetName: String
  ) {
    if let featuredWorkout, let resolvedMoment = workoutMoment(featuredWorkout) {
      return resolvedMoment
    }

    switch scenarioID {
    case "mock7_recovery":
      let title =
        (averageSleep ?? 0) < 420
        ? "把灯调暗，早一点休息"
        : "在安静的夜里好好睡了一觉"
      return (
        title,
        "Mori 把这一周留在暖灯和软毯之间，陪你慢一点。",
        WeeklyMemoryHighlight(title: "安静休息", symbol: "bed.double.fill", durationMinutes: nil),
        "weekly_memory_recovery_rest"
      )
    case "mock7_rhythm":
      return (
        "回家的灯，每晚都准时亮起",
        "Mori 把夜路上的灯一盏盏点亮，晚上的节奏也慢慢安稳下来。",
        WeeklyMemoryHighlight(title: "夜晚有了节奏", symbol: "moon.fill", durationMinutes: nil),
        "weekly_memory_evening_rhythm"
      )
    case "mock7_active":
      switch averageSteps ?? 0 {
      case 0..<4_800:
        return (
          "从一小段海边散步开始",
          "Mori 陪你沿着海岸慢慢走，把这一周的第一串脚印留了下来。",
          WeeklyMemoryHighlight(title: "海边散步", symbol: "figure.walk", durationMinutes: nil),
          "weekly_memory_gentle_walk"
        )
      case 4_800..<5_800:
        return (
          "熟悉的海岸，又多走了一段",
          "这一周，Mori 陪你沿着弯弯的海岸线，走到了新的路标旁。",
          WeeklyMemoryHighlight(title: "路线变长了", symbol: "figure.walk", durationMinutes: nil),
          "weekly_memory_coastal_route"
        )
      case 5_800..<7_000:
        return (
          "跨过冰桥，去看看另一边",
          "脚印越过了窄窄的海湾，Mori 和你一起走进了新的海岸。",
          WeeklyMemoryHighlight(title: "跨过冰桥", symbol: "figure.walk", durationMinutes: nil),
          "weekly_memory_ice_bridge"
        )
      default:
        return (
          "脚印延伸到了更远的海岸",
          "这一周，Mori 陪你沿着雪路走上高处，再回头看看走过的路。",
          WeeklyMemoryHighlight(title: "走得更远", symbol: "figure.hiking", durationMinutes: nil),
          "weekly_memory_long_walk"
        )
      }
    case "mock7_sparse":
      return (
        "几段轻轻的脚印，也是一周",
        "Mori 把真正留下来的片段收好，装订成这一页回忆。",
        WeeklyMemoryHighlight(title: "零散小片段", symbol: "camera.fill", durationMinutes: nil),
        "weekly_memory_gentle_walk"
      )
    default:
      return (
        "沿着熟悉的海岸走过一周",
        "没有特别大的起伏，Mori 还是把每天的小脚印好好收了起来。",
        WeeklyMemoryHighlight(title: "平稳小日子", symbol: "heart.fill", durationMinutes: nil),
        "weekly_memory_gentle_walk"
      )
    }
  }

  private func workoutMoment(
    _ workout: WorkoutSummary
  ) -> (
    title: String,
    body: String,
    highlight: WeeklyMemoryHighlight,
    coverAssetName: String
  )? {
    let minutes = workout.durationMinutes
    switch workout.activity {
    case .walking:
      return (
        "从一小段海边散步开始",
        "Mori 陪你沿着海岸走了 \(minutes) 分钟，把这一周的第一串脚印留了下来。",
        WeeklyMemoryHighlight(
          title: "海边散步 · \(minutes) 分钟",
          symbol: "figure.walk",
          durationMinutes: minutes
        ),
        "weekly_memory_gentle_walk"
      )
    case .swimming:
      return (
        "在蓝色水面划开的那一周",
        "Mori 记住了这 \(minutes) 分钟游泳，水花把这一周变成了清亮的蓝色。",
        WeeklyMemoryHighlight(
          title: "游泳 · \(minutes) 分钟",
          symbol: "figure.pool.swim",
          durationMinutes: minutes
        ),
        "weekly_memory_swimming"
      )
    case .badminton:
      return (
        "把羽毛球打向海风",
        "轻轻的羽毛球来回飞了 \(minutes) 分钟，Mori 把这一拍留在了本周。",
        WeeklyMemoryHighlight(
          title: "羽毛球 · \(minutes) 分钟",
          symbol: "figure.badminton",
          durationMinutes: minutes
        ),
        "weekly_memory_badminton"
      )
    case .tennis:
      return (
        "夕阳下的一记正手球",
        "Mori 陪你在海边打了 \(minutes) 分钟网球，最后一球落在了金色夕阳里。",
        WeeklyMemoryHighlight(
          title: "网球 · \(minutes) 分钟",
          symbol: "figure.tennis",
          durationMinutes: minutes
        ),
        "weekly_memory_tennis"
      )
    case .soccer:
      return (
        "把足球踢向海风的那一周",
        "这一周最值得记住的，是和 Mori 踢了 \(minutes) 分钟足球。",
        WeeklyMemoryHighlight(
          title: "足球 · \(minutes) 分钟",
          symbol: "figure.soccer",
          durationMinutes: minutes
        ),
        "weekly_memory_soccer"
      )
    case .running:
      return (
        "沿着海岸跑起来",
        "Mori 陪你迎着海风跑了 \(minutes) 分钟，把轻快的脚步留在这一周。",
        WeeklyMemoryHighlight(
          title: "跑步 · \(minutes) 分钟",
          symbol: "figure.run",
          durationMinutes: minutes
        ),
        "weekly_memory_long_walk"
      )
    case .cycling:
      return (
        "沿着海岸骑向远处",
        "Mori 记住了这段 \(minutes) 分钟的骑行，冰海和路标一路向后退去。",
        WeeklyMemoryHighlight(
          title: "骑行 · \(minutes) 分钟",
          symbol: "figure.outdoor.cycle",
          durationMinutes: minutes
        ),
        "weekly_memory_coastal_route"
      )
    case .other:
      return nil
    }
  }

  private func average(_ values: [Int]) -> Double? {
    guard !values.isEmpty else { return nil }
    return Double(values.reduce(0, +)) / Double(values.count)
  }

  private func number(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }

  private func duration(_ minutes: Int) -> String {
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainder) 分"
  }

  private func shortDate(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = timeZone
    formatter.dateFormat = "M月d日"
    return formatter.string(from: date)
  }

  private func dateKey(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private func daySourceKey(_ day: HealthSnapshot) -> String {
    let workouts = day.workouts
      .map { "\($0.id.uuidString):\($0.activity.rawValue):\($0.durationMinutes)" }
      .joined(separator: ",")
    return [
      day.localDay.rawValue,
      day.sleepMinutes.map(String.init) ?? "nil",
      day.steps.map(String.init) ?? "nil",
      day.activeMinutes.map(String.init) ?? "nil",
      workouts,
    ].joined(separator: ":")
  }

  private func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
