import Foundation

public actor MockNearbyRangingClient: NearbyRangingClient {
  private let reportedCapability: NearbyCapability
  private let localToken: NearbyDiscoveryToken
  private var prepared = false
  private var running = false
  private var measurement: NearbyMeasurement?
  public private(set) var peerToken: NearbyDiscoveryToken?

  public init(
    capability: NearbyCapability,
    localToken: NearbyDiscoveryToken = NearbyDiscoveryToken(encodedValue: Data([0x01]))
  ) {
    reportedCapability = capability
    self.localToken = localToken
  }

  public func capability() -> NearbyCapability { reportedCapability }

  public func prepareLocalToken() throws -> NearbyDiscoveryToken {
    guard reportedCapability == .preciseDistance else {
      throw NearbyAdapterError.unavailable("Precise ranging is unavailable")
    }
    prepared = true
    return localToken
  }

  public func beginRanging(peerToken: NearbyDiscoveryToken) throws {
    guard prepared else { throw NearbyAdapterError.localTokenNotPrepared }
    guard !peerToken.encodedValue.isEmpty else { throw NearbyAdapterError.invalidPeerToken }
    self.peerToken = peerToken
    running = true
  }

  public func latestMeasurement() -> NearbyMeasurement? { measurement }

  public func stop() {
    running = false
    measurement = nil
  }

  public func emit(_ measurement: NearbyMeasurement) {
    guard running else { return }
    self.measurement = measurement
  }
}
