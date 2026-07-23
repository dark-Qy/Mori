#if canImport(NearbyInteraction) && (os(iOS) || os(watchOS))
  @preconcurrency import NearbyInteraction
  import Foundation

  public final class AppleNearbyRangingClient: NSObject, NearbyRangingClient, NISessionDelegate,
    @unchecked Sendable
  {
    private var session: NISession
    private let lock = NSLock()
    private let eventBroadcaster = NearbyEventBroadcaster()
    private var measurement: NearbyMeasurement?
    private var peerConfiguration: NINearbyPeerConfiguration?
    private var suspended = false

    public override init() {
      session = NISession()
      super.init()
      session.delegate = self
    }

    public func capability() async -> NearbyCapability {
      if NISession.deviceCapabilities.supportsPreciseDistanceMeasurement {
        return .preciseDistance
      }
      return .unavailable(reason: "Precise distance measurement is unsupported")
    }

    public func prepareLocalToken() async throws -> NearbyDiscoveryToken {
      let currentSession = lock.withLock { session }
      guard let token = currentSession.discoveryToken else {
        eventBroadcaster.yield(
          .failed(.unavailable("Nearby discovery token is unavailable"))
        )
        throw NearbyAdapterError.unavailable("Nearby discovery token is unavailable")
      }
      do {
        return NearbyDiscoveryToken(
          encodedValue: try NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
          )
        )
      } catch {
        eventBroadcaster.yield(.failed(.tokenEncodingFailed))
        throw NearbyAdapterError.tokenEncodingFailed
      }
    }

    public func beginRanging(peerToken: NearbyDiscoveryToken) async throws {
      guard
        let token = try? NSKeyedUnarchiver.unarchivedObject(
          ofClass: NIDiscoveryToken.self,
          from: peerToken.encodedValue
        )
      else {
        eventBroadcaster.yield(.failed(.invalidPeerToken))
        await stop()
        throw NearbyAdapterError.invalidPeerToken
      }
      let configuration = NINearbyPeerConfiguration(peerToken: token)
      let result = lock.withLock {
        let isReplacement = peerConfiguration != nil
        peerConfiguration = configuration
        measurement = nil
        suspended = false
        return (session: session, isReplacement: isReplacement)
      }
      result.session.run(configuration)
      if result.isReplacement {
        eventBroadcaster.yield(.reset(.peerChanged))
      }
    }

    public func latestMeasurement() async -> NearbyMeasurement? {
      lock.withLock { measurement }
    }

    public func events() -> AsyncStream<NearbyRangingEvent> {
      eventBroadcaster.stream()
    }

    public func stop() async {
      let replacement = NISession()
      replacement.delegate = self
      let previous = lock.withLock {
        let previous = session
        session = replacement
        measurement = nil
        peerConfiguration = nil
        suspended = false
        return previous
      }
      previous.invalidate()
      eventBroadcaster.yield(.reset(.stopped))
    }

    public func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
      guard let object = nearbyObjects.first else { return }
      let updatedMeasurement = NearbyMeasurement(
        distanceMeters: object.distance.map(Double.init),
        capturedAt: Date()
      )
      let accepted = lock.withLock {
        guard session === self.session else { return false }
        measurement = updatedMeasurement
        return true
      }
      if accepted {
        eventBroadcaster.yield(.measurement(updatedMeasurement))
      }
    }

    public func session(
      _ session: NISession,
      didRemove nearbyObjects: [NINearbyObject],
      reason: NINearbyObject.RemovalReason
    ) {
      let accepted = lock.withLock {
        guard session === self.session else { return false }
        measurement = nil
        return true
      }
      if accepted {
        eventBroadcaster.yield(.reset(.peerRemoved))
      }
    }

    public func sessionWasSuspended(_ session: NISession) {
      let accepted = lock.withLock {
        guard session === self.session else { return false }
        suspended = true
        measurement = nil
        return true
      }
      if accepted {
        eventBroadcaster.yield(.suspended)
      }
    }

    public func sessionSuspensionEnded(_ session: NISession) {
      let result = lock.withLock {
        guard session === self.session, suspended else {
          return (accepted: false, configuration: Optional<NINearbyPeerConfiguration>.none)
        }
        suspended = false
        return (accepted: true, configuration: peerConfiguration)
      }
      guard result.accepted else { return }
      if let configuration = result.configuration {
        session.run(configuration)
      }
      eventBroadcaster.yield(.resumed)
    }

    public func session(_ session: NISession, didInvalidateWith error: any Error) {
      let accepted = lock.withLock {
        guard session === self.session else { return false }
        measurement = nil
        peerConfiguration = nil
        suspended = false
        return true
      }
      guard accepted else { return }
      eventBroadcaster.yield(
        .failed(.sessionInvalidated(String(describing: error)))
      )
      eventBroadcaster.yield(.reset(.sessionInvalidated))
    }
  }
#endif
