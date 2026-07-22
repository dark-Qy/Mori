import Domain

public struct DailyHabitRuleEngine: Sendable {
  public static let ruleSetVersion = 1
  public static let ruleID = "phase1.habit.daily-opportunity"

  public init() {}

  public func vitalityAward(for completion: DailyHabitCompletion) -> Int? {
    guard
      completion.ruleID == Self.ruleID,
      completion.ruleSetVersion == Self.ruleSetVersion
    else { return nil }
    return completion.kind == .companionCheckIn ? 1 : 2
  }

  public func suggestedHabit(for theme: Theme) -> DailyHabitKind {
    switch theme {
    case .recovery: .microRest
    case .activity: .shortWalk
    case .rhythm: .windDown
    case .connection, .neutral: .companionCheckIn
    }
  }
}
