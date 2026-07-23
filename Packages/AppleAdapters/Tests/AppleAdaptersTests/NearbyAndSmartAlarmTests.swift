import Foundation
import Testing

@testable import AppleAdapters

@Suite("Nearby Interaction boundary")
struct NearbyAdapterTests {
  @Test func requiresExplicitTokenExchangeBeforeRanging() async throws {
    let client = MockNearbyRangingClient(capability: .preciseDistance)
    await #expect(throws: NearbyAdapterError.localTokenNotPrepared) {
      try await client.beginRanging(peerToken: NearbyDiscoveryToken(encodedValue: Data([0x02])))
    }
    let local = try await client.prepareLocalToken()
    #expect(local.encodedValue == Data([0x01]))
    try await client.beginRanging(peerToken: NearbyDiscoveryToken(encodedValue: Data([0x02])))
    #expect(await client.peerToken?.encodedValue == Data([0x02]))
  }

  @Test func measurementIsOnlyAvailableWhileRunning() async throws {
    let client = MockNearbyRangingClient(capability: .preciseDistance)
    await client.emit(NearbyMeasurement(distanceMeters: 0.1, capturedAt: Date()))
    #expect(await client.latestMeasurement() == nil)
    _ = try await client.prepareLocalToken()
    try await client.beginRanging(peerToken: NearbyDiscoveryToken(encodedValue: Data([0x02])))
    let measurement = NearbyMeasurement(distanceMeters: 0.12, capturedAt: Date())
    await client.emit(measurement)
    #expect(await client.latestMeasurement() == measurement)
    await client.stop()
    #expect(await client.latestMeasurement() == nil)
  }

  @Test func unavailableCapabilityDoesNotPretendToRange() async {
    let client = MockNearbyRangingClient(
      capability: .unavailable(reason: "simulator or unsupported hardware")
    )
    await #expect(throws: NearbyAdapterError.unavailable("Precise ranging is unavailable")) {
      try await client.prepareLocalToken()
    }
  }

  @Test func stopCreatesAFreshUsableMockSession() async throws {
    let client = MockNearbyRangingClient(capability: .preciseDistance)
    let peer = NearbyDiscoveryToken(encodedValue: Data([0x02]))

    _ = try await client.prepareLocalToken()
    try await client.beginRanging(peerToken: peer)
    await client.stop()

    await #expect(throws: NearbyAdapterError.localTokenNotPrepared) {
      try await client.beginRanging(peerToken: peer)
    }
    _ = try await client.prepareLocalToken()
    try await client.beginRanging(peerToken: peer)
    let measurement = NearbyMeasurement(distanceMeters: 0.08, capturedAt: Date())
    await client.emit(measurement)
    #expect(await client.latestMeasurement() == measurement)
  }

  @Test func pushEventsExposeMeasurementsSuspensionAndResume() async throws {
    let client = MockNearbyRangingClient(capability: .preciseDistance)
    let stream = client.events()
    let received = Task {
      var events: [NearbyRangingEvent] = []
      for await event in stream {
        events.append(event)
        if events.count == 3 { break }
      }
      return events
    }

    _ = try await client.prepareLocalToken()
    try await client.beginRanging(
      peerToken: NearbyDiscoveryToken(encodedValue: Data([0x02]))
    )
    let measurement = NearbyMeasurement(distanceMeters: 0.09, capturedAt: Date())
    await client.emit(measurement)
    await client.simulateSuspension()
    await client.simulateResume()

    #expect(
      await received.value
        == [.measurement(measurement), .suspended, .resumed]
    )
  }

  @Test func invalidationFailureAndResetAreObservable() async throws {
    let client = MockNearbyRangingClient(capability: .preciseDistance)
    let stream = client.events()
    let received = Task {
      var events: [NearbyRangingEvent] = []
      for await event in stream {
        events.append(event)
        if events.count == 2 { break }
      }
      return events
    }

    await client.simulateFailure(.sessionInvalidated("mock invalidation"))

    #expect(
      await received.value
        == [
          .failed(.sessionInvalidated("mock invalidation")),
          .reset(.sessionInvalidated),
        ]
    )
  }

  @Test func replacingPeerClearsOldMeasurementsAndSignalsReset() async throws {
    let client = MockNearbyRangingClient(capability: .preciseDistance)
    let stream = client.events()
    let received = Task<NearbyRangingEvent?, Never> {
      for await event in stream {
        if event == .reset(.peerChanged) {
          return event
        }
      }
      return nil
    }

    _ = try await client.prepareLocalToken()
    try await client.beginRanging(
      peerToken: NearbyDiscoveryToken(encodedValue: Data([0x02]))
    )
    let oldMeasurement = NearbyMeasurement(distanceMeters: 0.07, capturedAt: Date())
    await client.emit(oldMeasurement)
    #expect(await client.latestMeasurement() == oldMeasurement)

    try await client.beginRanging(
      peerToken: NearbyDiscoveryToken(encodedValue: Data([0x03]))
    )
    #expect(await client.peerToken?.encodedValue == Data([0x03]))
    #expect(await client.latestMeasurement() == nil)
    #expect(
      await received.value
        == NearbyRangingEvent.reset(NearbyResetReason.peerChanged)
    )
  }

  @Test func invalidPeerTokenStopsTheActiveMockSession() async throws {
    let client = MockNearbyRangingClient(capability: .preciseDistance)
    _ = try await client.prepareLocalToken()
    try await client.beginRanging(
      peerToken: NearbyDiscoveryToken(encodedValue: Data([0x02]))
    )
    await client.emit(NearbyMeasurement(distanceMeters: 0.07, capturedAt: Date()))

    await #expect(throws: NearbyAdapterError.invalidPeerToken) {
      try await client.beginRanging(
        peerToken: NearbyDiscoveryToken(encodedValue: Data())
      )
    }
    #expect(await client.peerToken == nil)
    #expect(await client.latestMeasurement() == nil)

    await client.emit(NearbyMeasurement(distanceMeters: 0.06, capturedAt: Date()))
    #expect(await client.latestMeasurement() == nil)
  }
}

@Suite("Smart Alarm boundary")
struct SmartAlarmCapabilityTests {
  @Test func mockReportsExplicitUnverifiedState() async {
    let provider = MockSmartAlarmCapabilityProvider(.requiresPhysicalWatchVerification)
    #expect(await provider.capability() == .requiresPhysicalWatchVerification)
  }

  @Test func macOSDoesNotClaimWatchRuntimeSupport() async {
    #if os(macOS)
      let provider = AppleSmartAlarmCapabilityProvider()
      #expect(
        await provider.capability()
          == .unavailable(reason: "Smart Alarm extended runtime requires watchOS hardware")
      )
    #endif
  }
}
