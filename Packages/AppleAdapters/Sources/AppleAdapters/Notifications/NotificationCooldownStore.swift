import Foundation

public protocol NotificationCooldownStore: Sendable {
  func load() async -> Date?
  func save(_ date: Date?) async
}

public actor UserDefaultsNotificationCooldownStore: NotificationCooldownStore {
  private let defaults: UserDefaults
  private let key: String

  public init(
    defaults: UserDefaults = .standard,
    key: String = "app.notifications.last-scheduled-date.v1"
  ) {
    self.defaults = defaults
    self.key = key
  }

  public func load() -> Date? {
    defaults.object(forKey: key) as? Date
  }

  public func save(_ date: Date?) {
    if let date {
      defaults.set(date, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}

public actor InMemoryNotificationCooldownStore: NotificationCooldownStore {
  private var date: Date?

  public init(date: Date? = nil) {
    self.date = date
  }

  public func load() -> Date? { date }

  public func save(_ date: Date?) {
    self.date = date
  }
}
