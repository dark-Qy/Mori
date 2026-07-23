import Foundation

public struct RuntimeNotificationRoute: Equatable, Sendable {
  public let route: String
  public let parameters: [String: String]

  public init(route: String, parameters: [String: String] = [:]) {
    self.route = route
    self.parameters = parameters
  }
}

public enum RuntimeNotificationDestination: String, Equatable, Identifiable, Sendable {
  case recoveryMessage
  case activityMessage

  public var id: String { rawValue }
}

/// Maps a notification route to navigation intent only. This type has no event-engine dependency,
/// so opening or reopening a notification cannot settle growth, story, or habit rewards.
public struct NotificationRouteCoordinator: Sendable {
  public init() {}

  public func destination(for route: RuntimeNotificationRoute) -> RuntimeNotificationDestination? {
    switch route.route {
    case "pet/recovery": .recoveryMessage
    case "pet/activity": .activityMessage
    default: nil
    }
  }
}
