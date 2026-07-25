import AppleAdapters
import Domain
import Foundation

public struct ApprovedProactiveInteraction: Equatable, Sendable {
  public let id: String
  public let title: String
  public let body: String
  public let fireDate: Date
  public let route: String
  public let interruptionLevel: LocalNotificationInterruptionLevel

  public init(
    id: String,
    title: String,
    body: String,
    fireDate: Date,
    route: String,
    interruptionLevel: LocalNotificationInterruptionLevel = .active
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.fireDate = fireDate
    self.route = route
    self.interruptionLevel = interruptionLevel
  }
}

public struct CareCheckInPlanner: Sendable {
  public static let minimumSeededDelay: TimeInterval = 30 * 60
  public static let maximumSeededDelay: TimeInterval = 90 * 60
  public static let maximumEventAge: TimeInterval = 6 * 60 * 60

  public init() {}

  public func plan(
    for state: CompanionState,
    now: Date,
    delay: TimeInterval? = nil
  ) -> ApprovedProactiveInteraction? {
    guard
      let sample = state.lastStateOfMind,
      sample.requestsGentleCare,
      !state.handledStateOfMindSampleIDs.contains(sample.id),
      now >= sample.recordedAt,
      now.timeIntervalSince(sample.recordedAt) <= Self.maximumEventAge
    else { return nil }
    let selectedDelay = delay ?? seededDelay(for: sample)
    return ApprovedProactiveInteraction(
      id: "pet.state-of-mind.check-in",
      title: "Mori 想陪你待一会",
      body: "刚才是不是有点累？不用解释，要不要和我安静待一会儿？",
      fireDate: now.addingTimeInterval(max(60, selectedDelay)),
      route: "pet/care"
    )
  }

  private func seededDelay(for sample: StateOfMindSample) -> TimeInterval {
    let hash = sample.id.uuidString.utf8.reduce(0xCBF2_9CE4_8422_2325 as UInt64) { hash, byte in
      (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
    let minimumMinutes = Int(Self.minimumSeededDelay / 60)
    let maximumMinutes = Int(Self.maximumSeededDelay / 60)
    let minute = minimumMinutes + Int(hash % UInt64(maximumMinutes - minimumMinutes + 1))
    return TimeInterval(minute * 60)
  }
}

/// Rules select whether an interaction is allowed. This planner uses local, reviewed copy only;
/// AI output cannot create a schedule or bypass policy.
public struct ProactiveInteractionPlanner: Sendable {
  public static let minimumSeededDelay: TimeInterval = 10 * 60
  public static let maximumSeededDelay: TimeInterval = 90 * 60

  public init() {}

  /// Chooses a replay-stable minute inside the approved window. Policy still has final authority:
  /// quiet hours, consent, and cooldowns can suppress the resulting interaction entirely.
  public func plan(
    for state: CompanionState,
    now: Date
  ) -> ApprovedProactiveInteraction? {
    plan(for: state, now: now, delay: seededDelay(for: state))
  }

  public func plan(
    for state: CompanionState,
    now: Date,
    delay: TimeInterval
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

  private func seededDelay(for state: CompanionState) -> TimeInterval {
    let eventIdentity = state.processedEventIDs
      .map(\.uuidString)
      .sorted()
      .joined(separator: "|")
    let evaluatedAt = state.lastDecisionTrace?.evaluatedAt.timeIntervalSinceReferenceDate ?? 0
    let descriptor = "\(state.activeTheme.rawValue)|\(evaluatedAt)|\(eventIdentity)"
    let hash = descriptor.utf8.reduce(0xCBF2_9CE4_8422_2325 as UInt64) { hash, byte in
      (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
    let minimumMinutes = Int(Self.minimumSeededDelay / 60)
    let maximumMinutes = Int(Self.maximumSeededDelay / 60)
    let minute = minimumMinutes + Int(hash % UInt64(maximumMinutes - minimumMinutes + 1))
    return TimeInterval(minute * 60)
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
        deepLink: NotificationDeepLink(route: interaction.route),
        interruptionLevel: interaction.interruptionLevel
      ),
      policy: policy
    )
  }
}
