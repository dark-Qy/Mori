import Foundation

public enum NearbyCapability: Equatable, Sendable {
  case preciseDistance
  case unavailable(reason: String)
  case requiresPhysicalDeviceVerification
}

public struct NearbyDiscoveryToken: Codable, Equatable, Sendable {
  public let encodedValue: Data

  public init(encodedValue: Data) { self.encodedValue = encodedValue }
}

public struct NearbyMeasurement: Equatable, Sendable {
  public let distanceMeters: Double?
  public let capturedAt: Date

  public init(distanceMeters: Double?, capturedAt: Date) {
    self.distanceMeters = distanceMeters
    self.capturedAt = capturedAt
  }
}

public enum NearbyResetReason: Equatable, Sendable {
  case peerRemoved
  case peerChanged
  case stopped
  case sessionInvalidated
}

public enum NearbyRangingFailure: Equatable, Sendable {
  case unavailable(String)
  case tokenEncodingFailed
  case invalidPeerToken
  case localTokenNotPrepared
  case sessionInvalidated(String)
}

/// A push-based view of ranging changes. `latestMeasurement()` remains available
/// for callers that prefer polling.
public enum NearbyRangingEvent: Equatable, Sendable {
  case measurement(NearbyMeasurement)
  case suspended
  case resumed
  case reset(NearbyResetReason)
  case failed(NearbyRangingFailure)
}

/// Nearby Interaction performs proximity ranging only. The application must exchange
/// discovery tokens and all business data over a separate transport.
public protocol NearbyRangingClient: Sendable {
  func capability() async -> NearbyCapability
  func prepareLocalToken() async throws -> NearbyDiscoveryToken
  func beginRanging(peerToken: NearbyDiscoveryToken) async throws
  func latestMeasurement() async -> NearbyMeasurement?
  func events() -> AsyncStream<NearbyRangingEvent>
  func stop() async
}

extension NearbyRangingClient {
  /// Source-compatible fallback for adapters that only implement the original
  /// polling interface.
  public func events() -> AsyncStream<NearbyRangingEvent> {
    AsyncStream { continuation in
      continuation.finish()
    }
  }
}

public enum NearbyAdapterError: Error, Equatable, Sendable {
  case unavailable(String)
  case tokenEncodingFailed
  case invalidPeerToken
  case localTokenNotPrepared
}

final class NearbyEventBroadcaster: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<NearbyRangingEvent>.Continuation] = [:]

  func stream() -> AsyncStream<NearbyRangingEvent> {
    let identifier = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
      lock.withLock {
        continuations[identifier] = continuation
      }
      continuation.onTermination = { [weak self] _ in
        _ = self?.lock.withLock {
          self?.continuations.removeValue(forKey: identifier)
        }
      }
    }
  }

  func yield(_ event: NearbyRangingEvent) {
    let current = lock.withLock { Array(continuations.values) }
    for continuation in current {
      continuation.yield(event)
    }
  }
}
