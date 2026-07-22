#if canImport(UserNotifications) && (os(iOS) || os(watchOS))
  @preconcurrency import UserNotifications
  import Foundation

  public actor AppleLocalNotificationClient: LocalNotificationClient {
    private let center: UNUserNotificationCenter
    private let evaluator: NotificationPolicyEvaluator
    private var lastScheduledDate: Date?

    public init(
      center: UNUserNotificationCenter = .current(),
      calendar: Calendar = .current
    ) {
      self.center = center
      evaluator = NotificationPolicyEvaluator(calendar: calendar)
    }

    public func permissionState() async -> NotificationPermissionState {
      let settings = await center.notificationSettings()
      return Self.map(settings.authorizationStatus)
    }

    public func requestPermission() async -> NotificationPermissionState {
      let current = await permissionState()
      guard current == .notRequested else { return current }
      do {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await permissionState()
      } catch {
        return .unavailable(reason: error.localizedDescription)
      }
    }

    public func schedule(
      _ notification: LocalNotification,
      policy: NotificationPolicy
    ) async throws -> NotificationPolicyDecision {
      let state = await permissionState()
      guard state == .authorized || state == .provisional || state == .ephemeral else {
        throw NotificationAdapterError.permissionDenied
      }
      let decision = evaluator.evaluate(
        fireDate: notification.fireDate,
        lastScheduledDate: lastScheduledDate,
        policy: policy
      )
      guard decision == .allow else { return decision }

      let content = UNMutableNotificationContent()
      content.title = notification.title
      content.body = notification.body
      content.sound = .default
      if let deepLink = notification.deepLink {
        content.userInfo = [
          "route": deepLink.route,
          "parameters": deepLink.parameters,
        ]
      }
      let interval = max(1, notification.fireDate.timeIntervalSinceNow)
      let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
      do {
        try await center.add(
          UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger)
        )
        lastScheduledDate = notification.fireDate
        return .allow
      } catch {
        throw NotificationAdapterError.schedulingFailed(error.localizedDescription)
      }
    }

    public func cancel(id: String) async {
      center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    public func cancelAll() async {
      center.removeAllPendingNotificationRequests()
      lastScheduledDate = nil
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationPermissionState {
      switch status {
      case .notDetermined: return .notRequested
      case .denied: return .denied
      case .authorized: return .authorized
      case .provisional: return .provisional
      case .ephemeral: return .ephemeral
      @unknown default: return .unavailable(reason: "Unknown notification authorization state")
      }
    }
  }
#endif
