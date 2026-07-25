import Domain
import Foundation

struct ChatPersonalizationEvidenceFactory {
  func make(
    from message: MoriChatMessage,
    evidenceKey: String? = nil
  ) -> [PersonalizationSignal] {
    guard message.author == .owner else { return [] }
    let text = message.text.lowercased()
    let stableKey =
      evidenceKey?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? message.id.uuidString.lowercased()
    let evidencePrefix = "chat-\(stableKey)"
    var signals: [PersonalizationSignal] = []

    if containsPreferenceLanguage(text) {
      for (activity, keywords) in activityKeywords where text.contains(any: keywords) {
        signals.append(
          .explicitActivityPreference(
            activity: activity,
            affinity: 0.8,
            evidenceID: "\(evidencePrefix)-activity-\(activity.rawValue)"
          )
        )
      }

      for (interest, keywords) in interestKeywords where text.contains(any: keywords) {
        signals.append(
          .explicitInterest(
            interest: interest,
            affinity: 0.8,
            evidenceID: "\(evidencePrefix)-interest-\(interest.rawValue)"
          )
        )
      }
    }

    if let style = expressionStyle(in: text) {
      signals.append(
        .explicitExpressionPreference(
          style: style,
          evidenceID: "\(evidencePrefix)-expression-\(style.rawValue)"
        )
      )
    }

    if let rhythm = companionshipRhythm(in: text) {
      signals.append(
        .interactionRhythm(
          rhythm: rhythm,
          sampleCount: 1,
          evidenceID: "\(evidencePrefix)-rhythm-\(rhythm.rawValue)"
        )
      )
    }

    return signals
  }

  private var activityKeywords: [(WorkoutSummary.Activity, [String])] {
    [
      (.soccer, ["足球"]),
      (.swimming, ["游泳"]),
      (.badminton, ["羽毛球"]),
      (.tennis, ["网球"]),
      (.walking, ["散步", "走路"]),
      (.running, ["跑步", "慢跑"]),
      (.cycling, ["骑行", "骑车", "自行车"]),
    ]
  }

  private var interestKeywords: [(OwnerInterest, [String])] {
    [
      (.exploration, ["探索", "冒险", "旅行"]),
      (.movement, ["运动", "锻炼", "健身"]),
      (.outdoors, ["户外", "露营", "徒步", "爬山"]),
      (.quietMoments, ["独处", "安静待着", "发呆", "看书"]),
      (.racketSports, ["网球", "羽毛球"]),
      (.teamSports, ["足球", "篮球", "排球"]),
      (.waterSports, ["游泳", "潜水", "冲浪"]),
    ]
  }

  private func containsPreferenceLanguage(_ text: String) -> Bool {
    text.contains(
      any: [
        "我喜欢", "我爱", "我想", "经常", "常常", "习惯", "通常",
        "每周", "每天", "周末", "prefer", "usually", "often",
      ]
    )
  }

  private func expressionStyle(in text: String) -> MoriExpressionStyle? {
    if text.contains(
      any: ["直接一点", "直接点", "简短", "短一点", "少说", "别啰嗦", "不要啰嗦"]
    ) {
      return .concise
    }
    if text.contains(
      any: ["活泼一点", "开玩笑", "幽默一点", "可爱一点", "调皮一点"]
    ) {
      return .playful
    }
    if text.contains(any: ["温柔一点", "慢慢说", "柔和一点"]) {
      return .gentle
    }
    return nil
  }

  private func companionshipRhythm(in text: String) -> CompanionshipRhythm? {
    if text.contains(any: ["少聊", "安静陪", "别总说话", "不用一直说"]) {
      return .quiet
    }
    if text.contains(any: ["多聊", "主动一点", "热闹一点", "多说一点"]) {
      return .lively
    }
    return nil
  }
}

extension String {
  fileprivate func contains(any values: [String]) -> Bool {
    values.contains(where: contains)
  }
}
