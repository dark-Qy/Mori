import Foundation

/// Runtime policies depend on an injected clock so Mock scenarios and replay
/// tests never depend on the process wall clock.
public protocol MoriExperienceClock: Sendable {
  func now() async -> Date
}

public struct SystemMoriExperienceClock: MoriExperienceClock {
  public init() {}

  public func now() -> Date {
    Date()
  }
}

/// A manually advanced clock for deterministic Mock experiences.
public actor DeterministicMockExperienceClock: MoriExperienceClock {
  private var currentDate: Date

  public init(now: Date) {
    currentDate = now
  }

  public func now() -> Date {
    currentDate
  }

  public func set(_ date: Date) {
    currentDate = date
  }

  public func advance(by interval: TimeInterval) {
    guard interval.isFinite else { return }
    currentDate = currentDate.addingTimeInterval(interval)
  }
}
