import Domain
import Foundation

/// A value-semantic clock used by tests and debug scenario runners.
/// Advancing time returns predictable dates and never changes the system clock.
public struct TimeTravelClock: Clock, Codable, Equatable, Sendable {
  public private(set) var now: Date
  public let anchor: Date
  public let timeZoneIdentifier: String

  public init(anchor: Date, timeZoneIdentifier: String) {
    self.anchor = anchor
    now = anchor
    self.timeZoneIdentifier =
      TimeZone(identifier: timeZoneIdentifier)?.identifier
      ?? TimeZone(secondsFromGMT: 0)!.identifier
  }

  public var elapsed: TimeInterval {
    now.timeIntervalSince(anchor)
  }

  public mutating func advance(by interval: TimeInterval) {
    now = now.addingTimeInterval(interval)
  }

  public mutating func reset() {
    now = anchor
  }
}

public enum MockLaunchSelection: Equatable, Sendable {
  case none
  case scenario(String)
}

public enum MockLaunchArguments {
  /// Supports both XCTest-style `-MockScenario health_normal` and a convenient
  /// `--mock-scenario=health_normal` form. Release code decides whether to honor the result.
  public static func selection(from arguments: [String]) -> MockLaunchSelection {
    if let inline = arguments.first(where: { $0.hasPrefix("--mock-scenario=") }) {
      let identifier = String(inline.dropFirst("--mock-scenario=".count))
      return identifier.isEmpty ? .none : .scenario(identifier)
    }

    guard let flagIndex = arguments.firstIndex(of: "-MockScenario") else { return .none }
    let valueIndex = arguments.index(after: flagIndex)
    guard arguments.indices.contains(valueIndex), !arguments[valueIndex].isEmpty else {
      return .none
    }
    return .scenario(arguments[valueIndex])
  }
}
