public enum SmartAlarmCapability: Equatable, Sendable {
  case unavailable(reason: String)
  case requiresPhysicalWatchVerification
}

/// This boundary intentionally does not claim that extended runtime is usable.
/// Scheduling behavior, entitlement state, battery impact, and wake delivery require
/// a signed build on physical Apple Watch hardware.
public protocol SmartAlarmCapabilityProviding: Sendable {
  func capability() async -> SmartAlarmCapability
}

public struct AppleSmartAlarmCapabilityProvider: SmartAlarmCapabilityProviding {
  public init() {}

  public func capability() async -> SmartAlarmCapability {
    #if os(watchOS)
      return .requiresPhysicalWatchVerification
    #else
      return .unavailable(reason: "Smart Alarm extended runtime requires watchOS hardware")
    #endif
  }
}

public struct MockSmartAlarmCapabilityProvider: SmartAlarmCapabilityProviding {
  private let value: SmartAlarmCapability

  public init(_ value: SmartAlarmCapability) { self.value = value }
  public func capability() async -> SmartAlarmCapability { value }
}
