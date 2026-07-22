import Foundation

public enum RuleOutcome: String, Codable, Equatable, Sendable {
  case matched
  case notMatched
  case skipped
}

public struct RuleTraceStep: Codable, Equatable, Sendable {
  public var ruleID: String
  public var outcome: RuleOutcome
  public var explanation: String

  public init(ruleID: String, outcome: RuleOutcome, explanation: String) {
    self.ruleID = ruleID
    self.outcome = outcome
    self.explanation = explanation
  }
}

public struct DecisionTrace: Codable, Equatable, Sendable {
  public var ruleSetVersion: Int
  public var evaluatedAt: Date
  public var selectedTheme: Theme
  public var vitalityAward: Int
  public var steps: [RuleTraceStep]

  public init(
    ruleSetVersion: Int,
    evaluatedAt: Date,
    selectedTheme: Theme,
    vitalityAward: Int,
    steps: [RuleTraceStep]
  ) {
    self.ruleSetVersion = ruleSetVersion
    self.evaluatedAt = evaluatedAt
    self.selectedTheme = selectedTheme
    self.vitalityAward = max(0, vitalityAward)
    self.steps = steps
  }
}

public struct RuleDecision: Codable, Equatable, Sendable {
  public var theme: Theme
  public var vitalityAward: Int
  public var petMood: PetMood
  public var trace: DecisionTrace

  public init(theme: Theme, vitalityAward: Int, petMood: PetMood, trace: DecisionTrace) {
    self.theme = theme
    self.vitalityAward = max(0, vitalityAward)
    self.petMood = petMood
    self.trace = trace
  }
}
