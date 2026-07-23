import Foundation

public actor MockNearbyRangingClient: NearbyRangingClient {
  private let reportedCapability: NearbyCapability
  private let localToken: NearbyDiscoveryToken
  private nonisolated let eventBroadcaster = NearbyEventBroadcaster()
  private var prepared = false
  private var running = false
  private var suspended = false
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
      eventBroadcaster.yield(.failed(.unavailable("Precise ranging is unavailable")))
      throw NearbyAdapterError.unavailable("Precise ranging is unavailable")
    }
    prepared = true
    return localToken
  }

  public func beginRanging(peerToken: NearbyDiscoveryToken) throws {
    guard prepared else {
      eventBroadcaster.yield(.failed(.localTokenNotPrepared))
      throw NearbyAdapterError.localTokenNotPrepared
    }
    guard !peerToken.encodedValue.isEmpty else {
      eventBroadcaster.yield(.failed(.invalidPeerToken))
      running = false
      suspended = false
      self.peerToken = nil
      measurement = nil
      eventBroadcaster.yield(.reset(.sessionInvalidated))
      throw NearbyAdapterError.invalidPeerToken
    }
    let isReplacement = running && self.peerToken != peerToken
    self.peerToken = peerToken
    running = true
    suspended = false
    measurement = nil
    if isReplacement {
      eventBroadcaster.yield(.reset(.peerChanged))
    }
  }

  public func latestMeasurement() -> NearbyMeasurement? { measurement }

  public nonisolated func events() -> AsyncStream<NearbyRangingEvent> {
    eventBroadcaster.stream()
  }

  public func stop() {
    running = false
    suspended = false
    prepared = false
    peerToken = nil
    measurement = nil
    eventBroadcaster.yield(.reset(.stopped))
  }

  public func emit(_ measurement: NearbyMeasurement) {
    guard running, !suspended else { return }
    self.measurement = measurement
    eventBroadcaster.yield(.measurement(measurement))
  }

  public func simulateSuspension() {
    guard running, !suspended else { return }
    suspended = true
    measurement = nil
    eventBroadcaster.yield(.suspended)
  }

  public func simulateResume() {
    guard running, suspended else { return }
    suspended = false
    eventBroadcaster.yield(.resumed)
  }

  public func simulatePeerRemoval() {
    guard running else { return }
    measurement = nil
    eventBroadcaster.yield(.reset(.peerRemoved))
  }

  public func simulateFailure(_ failure: NearbyRangingFailure) {
    measurement = nil
    running = false
    suspended = false
    eventBroadcaster.yield(.failed(failure))
    eventBroadcaster.yield(.reset(.sessionInvalidated))
  }
}
