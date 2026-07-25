#if DEBUG
  import Foundation

  public struct MockSleepReminderSchedule: Equatable, Sendable {
    public static let defaultInterval: TimeInterval = 10

    public let interactions: [ApprovedProactiveInteraction]

    public init(
      selectionToken: String,
      now: Date = Date(),
      interval: TimeInterval = Self.defaultInterval
    ) {
      let resolvedInterval = max(1, interval)
      let messages = [
        "最近没休息好，要快点睡觉啦",
        "快快睡觉了～",
        "我好困困，我先睡觉惹，不管你啦！",
      ]
      interactions = messages.enumerated().map { index, message in
        ApprovedProactiveInteraction(
          id: "mock.sleep-reminder.\(selectionToken).\(index + 1)",
          title: "Mock 6 · 睡眠提醒",
          body: message,
          fireDate: now.addingTimeInterval(
            resolvedInterval * Double(index + 1)
          ),
          route: "pet/sleep",
          interruptionLevel: .active
        )
      }
    }
  }
#endif
