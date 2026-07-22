import Foundation

public actor MockLocalNotificationClient: LocalNotificationClient {
  private var state: NotificationPermissionState
  private let evaluator: NotificationPolicyEvaluator
  private let cooldownStore: any NotificationCooldownStore
  private var lastScheduledDate: Date?
  public private(set) var pending: [String: LocalNotification] = [:]
  public private(set) var permissionRequestCount = 0

  public init(
    state: NotificationPermissionState = .notRequested,
    calendar: Calendar = .current,
    cooldownStore: any NotificationCooldownStore = InMemoryNotificationCooldownStore()
  ) {
    self.state = state
    evaluator = NotificationPolicyEvaluator(calendar: calendar)
    self.cooldownStore = cooldownStore
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
  ) async throws -> NotificationPolicyDecision {
    guard state == .authorized || state == .provisional || state == .ephemeral else {
      throw NotificationAdapterError.permissionDenied
    }
    let persistedDate = await cooldownStore.load()
    let effectiveLastDate = [lastScheduledDate, persistedDate].compactMap { $0 }.max()
    let decision = evaluator.evaluate(
      fireDate: notification.fireDate,
      lastScheduledDate: effectiveLastDate,
      policy: policy
    )
    guard decision == .allow else { return decision }
    pending[notification.id] = notification
    lastScheduledDate = notification.fireDate
    await cooldownStore.save(notification.fireDate)
    return .allow
  }

  public func cancel(id: String) { pending.removeValue(forKey: id) }

  public func cancelAll() async {
    pending.removeAll()
    lastScheduledDate = nil
    await cooldownStore.save(nil)
  }
}
