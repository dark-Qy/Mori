#if canImport(UserNotifications) && (os(iOS) || os(watchOS))
  @preconcurrency import UserNotifications
  import Foundation

  public final class AppleNotificationResponseRouter: NSObject, UNUserNotificationCenterDelegate,
    @unchecked Sendable
  {
    private let center: UNUserNotificationCenter
    private let lock = NSLock()
    private var latest: NotificationDeepLink?
    private var observers: [UUID: AsyncStream<NotificationDeepLink>.Continuation] = [:]

    public init(center: UNUserNotificationCenter = .current()) {
      self.center = center
      super.init()
      center.delegate = self
    }

    public func routes() -> AsyncStream<NotificationDeepLink> {
      let observerID = UUID()
      return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let current = lock.withLock { () -> NotificationDeepLink? in
          observers[observerID] = continuation
          return latest
        }
        if let current { continuation.yield(current) }
        continuation.onTermination = { [weak self] _ in
          self?.lock.withLock { self?.observers[observerID] = nil }
        }
      }
    }

    public func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
      [.banner, .sound]
    }

    public func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      didReceive response: UNNotificationResponse
    ) async {
      guard
        let deepLink = NotificationResponseParser.deepLink(
          from: response.notification.request.content.userInfo)
      else { return }
      let currentObservers = lock.withLock {
        () -> [AsyncStream<NotificationDeepLink>.Continuation] in
        latest = deepLink
        return Array(observers.values)
      }
      for observer in currentObservers {
        observer.yield(deepLink)
      }
    }
  }
#endif
