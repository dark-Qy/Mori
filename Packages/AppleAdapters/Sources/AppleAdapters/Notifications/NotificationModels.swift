import Foundation

public enum NotificationPermissionState: Equatable, Sendable {
  case notRequested
  case authorized
  case denied
  case provisional
  case ephemeral
  case unavailable(reason: String)
}

public struct NotificationDeepLink: Codable, Equatable, Sendable {
  public let route: String
  public let parameters: [String: String]

  public init(route: String, parameters: [String: String] = [:]) {
    self.route = route
    self.parameters = parameters
  }
}

public struct LocalNotification: Equatable, Sendable {
  public let id: String
  public let title: String
  public let body: String
  public let fireDate: Date
  public let deepLink: NotificationDeepLink?

  public init(
    id: String,
    title: String,
    body: String,
    fireDate: Date,
    deepLink: NotificationDeepLink? = nil
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.fireDate = fireDate
    self.deepLink = deepLink
  }
}

public struct QuietHours: Equatable, Sendable {
  public let startMinute: Int
  public let endMinute: Int

  public init(startMinute: Int, endMinute: Int) {
    self.startMinute = max(0, min(1_439, startMinute))
    self.endMinute = max(0, min(1_439, endMinute))
  }

  public func contains(minuteOfDay: Int) -> Bool {
    if startMinute == endMinute { return false }
    if startMinute < endMinute {
      return minuteOfDay >= startMinute && minuteOfDay < endMinute
    }
    return minuteOfDay >= startMinute || minuteOfDay < endMinute
  }
}

public struct NotificationPolicy: Equatable, Sendable {
  public let quietHours: QuietHours?
  public let minimumCooldown: TimeInterval

  public init(quietHours: QuietHours? = nil, minimumCooldown: TimeInterval = 0) {
    self.quietHours = quietHours
    self.minimumCooldown = max(0, minimumCooldown)
  }
}

public enum NotificationPolicyDecision: Equatable, Sendable {
  case allow
  case suppressQuietHours
  case suppressCooldown(remainingSeconds: TimeInterval)
}

public struct NotificationPolicyEvaluator: Sendable {
  private let calendar: Calendar

  public init(calendar: Calendar = .current) { self.calendar = calendar }

  public func evaluate(
    fireDate: Date,
    lastScheduledDate: Date?,
    policy: NotificationPolicy
  ) -> NotificationPolicyDecision {
    if let quietHours = policy.quietHours {
      let components = calendar.dateComponents([.hour, .minute], from: fireDate)
      let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
      if quietHours.contains(minuteOfDay: minute) { return .suppressQuietHours }
    }
    if let lastScheduledDate {
      let elapsed = fireDate.timeIntervalSince(lastScheduledDate)
      if elapsed < policy.minimumCooldown {
        return .suppressCooldown(remainingSeconds: policy.minimumCooldown - elapsed)
      }
    }
    return .allow
  }
}

public protocol LocalNotificationClient: Sendable {
  func permissionState() async -> NotificationPermissionState
  func requestPermission() async -> NotificationPermissionState
  func schedule(_ notification: LocalNotification, policy: NotificationPolicy) async throws
    -> NotificationPolicyDecision
  func cancel(id: String) async
  func cancelAll() async
}

public enum NotificationAdapterError: Error, Equatable, Sendable {
  case permissionDenied
  case schedulingFailed(String)
}
