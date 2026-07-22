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
