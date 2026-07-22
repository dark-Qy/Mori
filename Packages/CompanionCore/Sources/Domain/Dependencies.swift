import Foundation

public protocol Clock: Sendable {
  var now: Date { get }
}

public protocol UUIDSource: Sendable {
  func makeUUID() -> UUID
}

/// Implementations are value types so a copied, seeded source can replay exactly.
public protocol RandomSource: Sendable {
  mutating func nextUnitInterval() -> Double
}

public struct SystemClock: Clock {
  public init() {}

  public var now: Date { Date() }
}

public struct SystemUUIDSource: UUIDSource {
  public init() {}

  public func makeUUID() -> UUID { UUID() }
}

public struct SystemRandomSource: RandomSource {
  public init() {}

  public mutating func nextUnitInterval() -> Double {
    Double.random(in: 0..<1)
  }
}
