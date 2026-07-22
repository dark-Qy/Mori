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

/// Nearby Interaction performs proximity ranging only. The application must exchange
/// discovery tokens and all business data over a separate transport.
public protocol NearbyRangingClient: Sendable {
  func capability() async -> NearbyCapability
  func prepareLocalToken() async throws -> NearbyDiscoveryToken
  func beginRanging(peerToken: NearbyDiscoveryToken) async throws
  func latestMeasurement() async -> NearbyMeasurement?
  func stop() async
}

public enum NearbyAdapterError: Error, Equatable, Sendable {
  case unavailable(String)
  case tokenEncodingFailed
  case invalidPeerToken
  case localTokenNotPrepared
}
