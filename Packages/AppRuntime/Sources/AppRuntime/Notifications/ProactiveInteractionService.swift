import AppleAdapters
import Domain
import Foundation

public struct ApprovedProactiveInteraction: Equatable, Sendable {
  public let id: String
  public let title: String
  public let body: String
  public let fireDate: Date
  public let route: String

  public init(id: String, title: String, body: String, fireDate: Date, route: String) {
    self.id = id
    self.title = title
    self.body = body
    self.fireDate = fireDate
    self.route = route
  }
}

/// Rules select whether an interaction is allowed. This planner uses local, reviewed copy only;
/// AI output cannot create a schedule or bypass policy.
public struct ProactiveInteractionPlanner: Sendable {
  public init() {}

  public func plan(
    for state: CompanionState,
    now: Date,
    delay: TimeInterval = 30 * 60
  ) -> ApprovedProactiveInteraction? {
    guard state.lastDecisionTrace != nil else { return nil }
    let fireDate = now.addingTimeInterval(max(60, delay))
    switch state.activeTheme {
    case .recovery:
      return ApprovedProactiveInteraction(
        id: "pet.recovery.check-in",
        title: "Mori 来看看你",
        body: "今天可以慢一点。要不要留十分钟给自己？",
        fireDate: fireDate,
        route: "pet/recovery"
      )
    case .activity:
      let lowActivityMatched =
        state.lastDecisionTrace?.steps.contains {
          $0.ruleID == "phase1.theme.activity.low-activity" && $0.outcome == .matched
        } == true
      return ApprovedProactiveInteraction(
        id: "pet.activity.check-in",
        title: lowActivityMatched ? "Mori 想去窗边看看" : "Mori 想听冒险故事",
        body: lowActivityMatched
          ? "如果你愿意，我们可以一起走两分钟；不完成也不会失去什么。"
          : "今天的活动进度已经记下了，记得给身体一个舒服的收尾。",
        fireDate: fireDate,
        route: "pet/activity"
      )
    case .rhythm, .connection, .neutral:
      return nil
    }
  }
}

public struct ProactiveInteractionService<Client: LocalNotificationClient>: Sendable {
  public var client: Client

  public init(client: Client) {
    self.client = client
  }

  public func schedule(
    _ interaction: ApprovedProactiveInteraction,
    policy: NotificationPolicy
  ) async throws -> NotificationPolicyDecision {
    try await client.schedule(
      LocalNotification(
        id: interaction.id,
        title: interaction.title,
        body: interaction.body,
        fireDate: interaction.fireDate,
        deepLink: NotificationDeepLink(route: interaction.route)
      ),
      policy: policy
    )
  }
}
