import Domain

public struct SoccerSideStoryRule: Sendable {
  public static let ruleSetVersion = 1
  public static let ruleID = "phase1.story.soccer-workout"

  public var minimumDurationMinutes: Int

  public init(minimumDurationMinutes: Int = 20) {
    self.minimumDurationMinutes = max(1, minimumDurationMinutes)
  }

  public func qualifyingWorkout(in snapshot: HealthSnapshot) -> WorkoutSummary? {
    guard snapshot.canInformRules else { return nil }
    return snapshot.workouts
      .filter { $0.activity == .soccer && $0.durationMinutes >= minimumDurationMinutes }
      .sorted { lhs, rhs in
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.id.uuidString < rhs.id.uuidString
      }
      .last
  }
}
