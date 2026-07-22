import Foundation

public enum NotificationResponseParser {
  public static func deepLink(from userInfo: [AnyHashable: Any]) -> NotificationDeepLink? {
    guard let route = userInfo["route"] as? String, !route.isEmpty else { return nil }
    let parameters = userInfo["parameters"] as? [String: String] ?? [:]
    return NotificationDeepLink(route: route, parameters: parameters)
  }
}
