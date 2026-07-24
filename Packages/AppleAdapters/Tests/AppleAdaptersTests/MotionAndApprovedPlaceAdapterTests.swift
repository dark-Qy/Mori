import Foundation
import Testing

@testable import AppleAdapters

@Suite("Broad motion adapter boundary")
struct BroadMotionAdapterTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func emitsOnlyBroadClassificationConfidenceAndTime() async throws {
    let client = MockBroadMotionActivityClient()
    let stream = client.events()
    let received = Task<BroadMotionEvent?, Never> {
      for await event in stream {
        return event
      }
      return nil
    }
    let observation = BroadMotionObservation(
      activity: .walking,
      confidence: .high,
      observedAt: now
    )

    try await client.start()
    await client.emit(observation)

    #expect(await received.value == .observation(observation))
    let encoded = try JSONEncoder().encode(observation)
    let object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(Set(object.keys) == ["activity", "confidence", "observedAt"])
    let json = String(decoding: encoded, as: UTF8.self)
    #expect(!json.localizedCaseInsensitiveContains("accelerometer"))
    #expect(!json.localizedCaseInsensitiveContains("gyroscope"))
  }

  @Test func permissionAndAvailabilityFailuresAreExplicit() async {
    let denied = MockBroadMotionActivityClient(permission: .denied)
    #expect(await denied.permissionState() == .denied)
    await #expect(throws: BroadMotionAdapterError.permissionDenied) {
      try await denied.start()
    }

    let unavailable = MockBroadMotionActivityClient(
      availability: .unavailable(reason: "test hardware")
    )
    #expect(await unavailable.availability() == .unavailable(reason: "test hardware"))
    await #expect(throws: BroadMotionAdapterError.unavailable("test hardware")) {
      try await unavailable.start()
    }
  }

  @Test func stopAndReplacementFenceStaleCallbacks() async throws {
    let client = MockBroadMotionActivityClient()
    let stream = client.events()
    let received = Task<[BroadMotionEvent], Never> {
      var events: [BroadMotionEvent] = []
      for await event in stream {
        events.append(event)
        if events.count == 2 { break }
      }
      return events
    }

    try await client.start()
    let staleGeneration = await client.currentCallbackGeneration()
    await client.stop()
    try await client.start()
    let accepted = BroadMotionObservation(
      activity: .running,
      confidence: .medium,
      observedAt: now
    )
    await client.emit(
      BroadMotionObservation(
        activity: .automotive,
        confidence: .low,
        observedAt: now.addingTimeInterval(-10)
      ),
      callbackGeneration: staleGeneration
    )
    await client.emit(accepted)

    #expect(await received.value == [.stopped, .observation(accepted)])
  }

  @Test func permissionRevocationStopsTheSessionBeforeAnotherObservation() async throws {
    let client = MockBroadMotionActivityClient()
    let stream = client.events()
    let received = Task<[BroadMotionEvent], Never> {
      var events: [BroadMotionEvent] = []
      for await event in stream {
        events.append(event)
        if events.count == 2 { break }
      }
      return events
    }

    try await client.start()
    let authorizedGeneration = await client.currentCallbackGeneration()
    await client.setPermissionState(.denied)
    await client.emit(
      BroadMotionObservation(
        activity: .walking,
        confidence: .high,
        observedAt: now
      ),
      callbackGeneration: authorizedGeneration
    )

    #expect(await client.isRunning() == false)
    #expect(await client.currentCallbackGeneration() != authorizedGeneration)
    #expect(
      await received.value
        == [.permissionChanged(.denied), .failed(.permissionDenied)]
    )
  }

  @Test func notDeterminedPermissionCannotEmitBeforeAuthorization() async throws {
    let client = MockBroadMotionActivityClient(permission: .notDetermined)
    let stream = client.events()
    let received = Task<[BroadMotionEvent], Never> {
      var events: [BroadMotionEvent] = []
      for await event in stream {
        events.append(event)
        if events.count == 2 { break }
      }
      return events
    }
    let observation = BroadMotionObservation(
      activity: .walking,
      confidence: .medium,
      observedAt: now
    )

    try await client.start()
    await client.emit(observation)
    await client.setPermissionState(.authorized)
    await client.emit(observation)

    #expect(
      await received.value
        == [.permissionChanged(.authorized), .observation(observation)]
    )
  }

  @Test func cancellingAnEventSubscriptionFinishesTheConsumer() async {
    let client = MockBroadMotionActivityClient()
    let consumer = Task {
      for await _ in client.events() {}
    }

    consumer.cancel()
    await consumer.value
  }

  @Test func macOSFallbackDoesNotClaimLiveClassifierSupport() async {
    #if os(macOS)
      let client = AppleBroadMotionActivityClient()
      #expect(
        await client.availability()
          == .unavailable(reason: "Broad motion classification is unavailable on this platform")
      )
    #endif
  }
}

@Suite("Approved place adapter boundary")
struct ApprovedPlaceAdapterTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func emitsApprovedCategoryPresenceAndTimeWithoutCoordinates() async throws {
    let client = MockApprovedPlaceMonitoringClient()
    let stream = client.events()
    let received = Task<ApprovedPlaceMonitoringEvent?, Never> {
      for await event in stream {
        return event
      }
      return nil
    }
    let region = approvedRegion(category: .park)
    try await client.startMonitoring([region])
    await client.emit(category: .park, presence: .entered, observedAt: now)

    let expected = ApprovedPlaceObservation(
      category: .park,
      presence: .entered,
      observedAt: now
    )
    #expect(await received.value == .observation(expected))

    let encoded = try JSONEncoder().encode(expected)
    let object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(Set(object.keys) == ["category", "presence", "observedAt"])
    #expect(object["category"] as? String == "park")
    let json = String(decoding: encoded, as: UTF8.self)
    #expect(!json.localizedCaseInsensitiveContains("latitude"))
    #expect(!json.localizedCaseInsensitiveContains("longitude"))
    #expect(!json.localizedCaseInsensitiveContains("radius"))
    #expect(!json.localizedCaseInsensitiveContains("route"))
  }

  @Test func permissionRequestAndMonitoringStateAreExplicit() async throws {
    let client = MockApprovedPlaceMonitoringClient(permission: .notDetermined)
    await #expect(throws: ApprovedPlaceAdapterError.permissionNotDetermined) {
      try await client.startMonitoring([self.approvedRegion(category: .home)])
    }

    await client.requestPermission(.always)
    #expect(await client.permissionState() == .authorizedAlways)
    try await client.startMonitoring([approvedRegion(category: .home)])
  }

  @Test func invalidOrExcessiveRegionsFailBeforeMonitoring() async {
    let client = MockApprovedPlaceMonitoringClient()
    let invalid = DeviceLocalApprovedRegion(
      category: .home,
      center: DeviceLocalCoordinate(latitude: 91, longitude: 0),
      radiusMeters: 100
    )
    await #expect(throws: ApprovedPlaceAdapterError.invalidRegion) {
      try await client.startMonitoring([invalid])
    }

    let tooMany = Array(
      repeating: approvedRegion(category: .other),
      count: MockApprovedPlaceMonitoringClient.maximumRegionCount + 1
    )
    await #expect(
      throws: ApprovedPlaceAdapterError.tooManyRegions(
        maximum: MockApprovedPlaceMonitoringClient.maximumRegionCount
      )
    ) {
      try await client.startMonitoring(tooMany)
    }
  }

  @Test func unapprovedAndStaleCallbacksCannotEmit() async throws {
    let client = MockApprovedPlaceMonitoringClient()
    let stream = client.events()
    let received = Task<[ApprovedPlaceMonitoringEvent], Never> {
      var events: [ApprovedPlaceMonitoringEvent] = []
      for await event in stream {
        events.append(event)
        if events.count == 2 { break }
      }
      return events
    }

    try await client.startMonitoring([approvedRegion(category: .home)])
    let staleGeneration = await client.currentCallbackGeneration()
    await client.stop()
    try await client.startMonitoring([approvedRegion(category: .work)])
    await client.emit(
      category: .home,
      presence: .entered,
      observedAt: now,
      callbackGeneration: staleGeneration
    )
    await client.emit(category: .transit, presence: .entered, observedAt: now)
    await client.emit(category: .work, presence: .exited, observedAt: now)

    #expect(
      await received.value
        == [
          .stopped,
          .observation(
            ApprovedPlaceObservation(
              category: .work,
              presence: .exited,
              observedAt: now
            )
          ),
        ]
    )
  }

  @Test func permissionRevocationStopsApprovedPlaceMonitoring() async throws {
    let client = MockApprovedPlaceMonitoringClient()
    let stream = client.events()
    let received = Task<[ApprovedPlaceMonitoringEvent], Never> {
      var events: [ApprovedPlaceMonitoringEvent] = []
      for await event in stream {
        events.append(event)
        if events.count == 2 { break }
      }
      return events
    }

    try await client.startMonitoring([approvedRegion(category: .home)])
    let authorizedGeneration = await client.currentCallbackGeneration()
    await client.setPermissionState(.restricted)
    await client.emit(
      category: .home,
      presence: .entered,
      observedAt: now,
      callbackGeneration: authorizedGeneration
    )

    #expect(await client.isMonitoring() == false)
    #expect(await client.currentCallbackGeneration() != authorizedGeneration)
    #expect(
      await received.value
        == [.permissionChanged(.restricted), .failed(.permissionRestricted)]
    )
  }

  @Test func staleSystemFailuresAreFencedAndStartDoesNotInventAPresenceEvent() async throws {
    let client = MockApprovedPlaceMonitoringClient()
    let stream = client.events()
    let received = Task<[ApprovedPlaceMonitoringEvent], Never> {
      var events: [ApprovedPlaceMonitoringEvent] = []
      for await event in stream {
        events.append(event)
        if events.count == 2 { break }
      }
      return events
    }

    try await client.startMonitoring([approvedRegion(category: .home)])
    let staleGeneration = await client.currentCallbackGeneration()
    await client.stop()
    try await client.startMonitoring([approvedRegion(category: .work)])
    await client.simulateSystemFailure(callbackGeneration: staleGeneration)
    let currentGeneration = await client.currentCallbackGeneration()
    await client.simulateSystemFailure(callbackGeneration: currentGeneration)

    #expect(
      await received.value
        == [.stopped, .failed(.systemFailure)]
    )
  }

  private func approvedRegion(
    category: ApprovedPlaceCategory
  ) -> DeviceLocalApprovedRegion {
    DeviceLocalApprovedRegion(
      category: category,
      center: DeviceLocalCoordinate(latitude: 31.2304, longitude: 121.4737),
      radiusMeters: 150
    )
  }
}
