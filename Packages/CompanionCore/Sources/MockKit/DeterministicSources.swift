#if DEBUG
  import Domain
  import Foundation

  public struct FixedClock: Clock {
    public var now: Date

    public init(now: Date) {
      self.now = now
    }
  }

  public struct FixedUUIDSource: UUIDSource {
    public var value: UUID

    public init(_ value: UUID) {
      self.value = value
    }

    public func makeUUID() -> UUID { value }
  }

  /// SplitMix64 is small, deterministic, and appropriate for reproducible fixtures (not security).
  public struct SeededRandomSource: RandomSource, Equatable {
    private var state: UInt64

    public init(seed: UInt64) {
      state = seed
    }

    public mutating func nextUnitInterval() -> Double {
      state &+= 0x9E37_79B9_7F4A_7C15
      var value = state
      value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
      value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
      value ^= value >> 31
      return Double(value >> 11) / 9_007_199_254_740_992.0
    }
  }

  public struct MockEventFactory<C: Clock, U: UUIDSource>: Sendable {
    public var clock: C
    public var uuidSource: U

    public init(clock: C, uuidSource: U) {
      self.clock = clock
      self.uuidSource = uuidSource
    }

    public func make(_ payload: DomainEvent, source: EventSource = .mock) -> EventEnvelope {
      EventEnvelope(
        eventID: uuidSource.makeUUID(),
        occurredAt: clock.now,
        source: source,
        payload: payload
      )
    }
  }
#endif
