#if canImport(NearbyInteraction) && (os(iOS) || os(watchOS))
  @preconcurrency import NearbyInteraction
  import Foundation

  public final class AppleNearbyRangingClient: NSObject, NearbyRangingClient, NISessionDelegate,
    @unchecked Sendable
  {
    private let session: NISession
    private let lock = NSLock()
    private var measurement: NearbyMeasurement?

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
      guard let token = session.discoveryToken else {
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
        throw NearbyAdapterError.tokenEncodingFailed
      }
    }

    public func beginRanging(peerToken: NearbyDiscoveryToken) async throws {
      guard
        let token = try? NSKeyedUnarchiver.unarchivedObject(
          ofClass: NIDiscoveryToken.self,
          from: peerToken.encodedValue
        )
      else { throw NearbyAdapterError.invalidPeerToken }
      session.run(NINearbyPeerConfiguration(peerToken: token))
    }

    public func latestMeasurement() async -> NearbyMeasurement? {
      lock.withLock { measurement }
    }

    public func stop() async {
      session.invalidate()
      lock.withLock { measurement = nil }
    }

    public func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
      guard let object = nearbyObjects.first else { return }
      lock.withLock {
        measurement = NearbyMeasurement(
          distanceMeters: object.distance.map(Double.init),
          capturedAt: Date()
        )
      }
    }

    public func session(
      _ session: NISession,
      didRemove nearbyObjects: [NINearbyObject],
      reason: NINearbyObject.RemovalReason
    ) {
      lock.withLock { measurement = nil }
    }

    public func sessionWasSuspended(_ session: NISession) {}
    public func sessionSuspensionEnded(_ session: NISession) {}
    public func session(_ session: NISession, didInvalidateWith error: any Error) {
      lock.withLock { measurement = nil }
    }
  }
#endif
