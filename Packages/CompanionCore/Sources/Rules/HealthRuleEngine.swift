import Domain
import Foundation

public struct PhaseOneRuleConfiguration: Codable, Equatable, Sendable {
  public var lowSleepMinutes: Int
  public var restorativeSleepMinutes: Int
  public var lowActivityMinutes: Int
  public var activityGoalMinutes: Int
  public var lowStepCount: Int
  public var stepGoal: Int
  public var maximumVitalityAward: Int
  public var maximumFreshAgeSeconds: TimeInterval
  public var futureToleranceSeconds: TimeInterval

  public init(
    lowSleepMinutes: Int = 360,
    restorativeSleepMinutes: Int = 420,
    lowActivityMinutes: Int = 15,
    activityGoalMinutes: Int = 30,
    lowStepCount: Int = 3_000,
    stepGoal: Int = 8_000,
    maximumVitalityAward: Int = 5,
    maximumFreshAgeSeconds: TimeInterval = 36 * 60 * 60,
    futureToleranceSeconds: TimeInterval = 5 * 60
  ) {
    self.lowSleepMinutes = lowSleepMinutes
    self.restorativeSleepMinutes = restorativeSleepMinutes
    self.lowActivityMinutes = lowActivityMinutes
    self.activityGoalMinutes = activityGoalMinutes
    self.lowStepCount = lowStepCount
    self.stepGoal = stepGoal
    self.maximumVitalityAward = max(0, maximumVitalityAward)
    self.maximumFreshAgeSeconds = max(0, maximumFreshAgeSeconds)
    self.futureToleranceSeconds = max(0, futureToleranceSeconds)
  }
}

/// Deterministic Phase 1 policy. It only grants vitality; health outcomes never deduct it.
public struct HealthRuleEngine: Sendable {
  public static let ruleSetVersion = 1

  public var configuration: PhaseOneRuleConfiguration

  public init(configuration: PhaseOneRuleConfiguration = PhaseOneRuleConfiguration()) {
    self.configuration = configuration
  }

  public func evaluate(_ snapshot: HealthSnapshot, at evaluatedAt: Date) -> RuleDecision {
    guard snapshot.canInformRules && isTemporallyFresh(snapshot, at: evaluatedAt) else {
      return neutralDecision(for: snapshot, at: evaluatedAt)
    }

    var steps: [RuleTraceStep] = []
    var award = 0

    let lowSleep = snapshot.sleepMinutes.map { $0 < configuration.lowSleepMinutes } ?? false
    steps.append(
      RuleTraceStep(
        ruleID: "phase1.theme.recovery.low-sleep",
        outcome: snapshot.sleepMinutes == nil ? .skipped : (lowSleep ? .matched : .notMatched),
        explanation: lowSleep
          ? "Sleep was below the configured recovery threshold." : "No low-sleep recovery trigger."
      )
    )

    let lowActivity = isLowActivity(snapshot)
    steps.append(
      RuleTraceStep(
        ruleID: "phase1.theme.activity.low-activity",
        outcome: hasActivityInput(snapshot) ? (lowActivity ? .matched : .notMatched) : .skipped,
        explanation: lowActivity
          ? "Available movement metrics were below the activity threshold."
          : "No low-activity trigger."
      )
    )

    if let sleep = snapshot.sleepMinutes, sleep >= configuration.restorativeSleepMinutes {
      award += 2
      steps.append(
        RuleTraceStep(
          ruleID: "phase1.vitality.restorative-sleep",
          outcome: .matched,
          explanation: "The restorative sleep threshold was met."
        )
      )
    } else {
      steps.append(
        RuleTraceStep(
          ruleID: "phase1.vitality.restorative-sleep",
          outcome: snapshot.sleepMinutes == nil ? .skipped : .notMatched,
          explanation: "No restorative-sleep vitality award."
        )
      )
    }

    if let activeMinutes = snapshot.activeMinutes,
      activeMinutes >= configuration.activityGoalMinutes
    {
      award += 3
      steps.append(
        RuleTraceStep(
          ruleID: "phase1.vitality.active-minutes",
          outcome: .matched,
          explanation: "The active-minutes goal was met."
        )
      )
    } else {
      steps.append(
        RuleTraceStep(
          ruleID: "phase1.vitality.active-minutes",
          outcome: snapshot.activeMinutes == nil ? .skipped : .notMatched,
          explanation: "No active-minutes vitality award."
        )
      )
    }

    if let stepsValue = snapshot.steps, stepsValue >= configuration.stepGoal {
      award += 2
      steps.append(
        RuleTraceStep(
          ruleID: "phase1.vitality.steps",
          outcome: .matched,
          explanation: "The step goal was met."
        )
      )
    } else {
      steps.append(
        RuleTraceStep(
          ruleID: "phase1.vitality.steps",
          outcome: snapshot.steps == nil ? .skipped : .notMatched,
          explanation: "No step vitality award."
        )
      )
    }

    award = min(award, configuration.maximumVitalityAward)
    let theme: Theme
    let mood: PetMood
    if lowSleep {
      theme = .recovery
      mood = .resting
    } else if lowActivity {
      theme = .activity
      mood = .curious
    } else if award > 0 {
      theme = .activity
      mood = .lively
    } else {
      theme = .neutral
      mood = .neutral
    }

    let trace = DecisionTrace(
      ruleSetVersion: Self.ruleSetVersion,
      evaluatedAt: evaluatedAt,
      selectedTheme: theme,
      vitalityAward: award,
      steps: steps
    )
    return RuleDecision(theme: theme, vitalityAward: award, petMood: mood, trace: trace)
  }

  private func neutralDecision(for snapshot: HealthSnapshot, at evaluatedAt: Date) -> RuleDecision {
    let explanation: String
    switch snapshot.requestState {
    case .unavailable:
      explanation = "Health capability is unavailable; no user condition was inferred."
    case .notRequested:
      explanation = "Health access has not been requested; no user condition was inferred."
    case .requestCompleted:
      explanation =
        snapshot.freshness == .stale || !isTemporallyFresh(snapshot, at: evaluatedAt)
        ? "Health data is stale; no current condition was inferred."
        : "No usable health metrics are available; state remains neutral."
    }

    let trace = DecisionTrace(
      ruleSetVersion: Self.ruleSetVersion,
      evaluatedAt: evaluatedAt,
      selectedTheme: .neutral,
      vitalityAward: 0,
      steps: [
        RuleTraceStep(
          ruleID: "phase1.guard.usable-health-data",
          outcome: .skipped,
          explanation: explanation
        )
      ]
    )
    return RuleDecision(theme: .neutral, vitalityAward: 0, petMood: .neutral, trace: trace)
  }

  private func hasActivityInput(_ snapshot: HealthSnapshot) -> Bool {
    snapshot.activeMinutes != nil || snapshot.steps != nil
  }

  private func isTemporallyFresh(_ snapshot: HealthSnapshot, at evaluatedAt: Date) -> Bool {
    let age = evaluatedAt.timeIntervalSince(snapshot.capturedAt)
    return age >= -configuration.futureToleranceSeconds
      && age <= configuration.maximumFreshAgeSeconds
  }

  private func isLowActivity(_ snapshot: HealthSnapshot) -> Bool {
    let activeMinutesLow = snapshot.activeMinutes.map { $0 < configuration.lowActivityMinutes }
    let stepsLow = snapshot.steps.map { $0 < configuration.lowStepCount }
    switch (activeMinutesLow, stepsLow) {
    case (.some(let active), .some(let steps)):
      return active && steps
    case (.some(let active), .none):
      return active
    case (.none, .some(let steps)):
      return steps
    case (.none, .none):
      return false
    }
  }
}
