import Foundation

public actor MockLocalNotificationClient: LocalNotificationClient {
  private var state: NotificationPermissionState
  private let evaluator: NotificationPolicyEvaluator
  private var lastScheduledDate: Date?
  public private(set) var pending: [String: LocalNotification] = [:]
  public private(set) var permissionRequestCount = 0

  public init(
    state: NotificationPermissionState = .notRequested,
    calendar: Calendar = .current
  ) {
    self.state = state
    evaluator = NotificationPolicyEvaluator(calendar: calendar)
  }

  public func permissionState() -> NotificationPermissionState { state }

  public func requestPermission() -> NotificationPermissionState {
    guard state == .notRequested else { return state }
    permissionRequestCount += 1
    state = .authorized
    return state
  }

  public func schedule(
    _ notification: LocalNotification,
    policy: NotificationPolicy
  ) throws -> NotificationPolicyDecision {
    guard state == .authorized || state == .provisional || state == .ephemeral else {
      throw NotificationAdapterError.permissionDenied
    }
    let decision = evaluator.evaluate(
      fireDate: notification.fireDate,
      lastScheduledDate: lastScheduledDate,
      policy: policy
    )
    guard decision == .allow else { return decision }
    pending[notification.id] = notification
    lastScheduledDate = notification.fireDate
    return .allow
  }

  public func cancel(id: String) { pending.removeValue(forKey: id) }

  public func cancelAll() {
    pending.removeAll()
    lastScheduledDate = nil
  }
}
