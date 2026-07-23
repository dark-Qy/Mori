#if DEBUG
  import Domain
  import Foundation
  import Growth
  import Persistence

  public enum MockScenarioError: Error, Equatable, Sendable {
    case missingValue(String)
    case invalidValue(String)
    case expectationMismatch(String)
  }

  public enum MockPrimaryState: String, Equatable, Sendable {
    case onboarding
    case petIntroduction
    case petHome
    case wardrobe
  }

  public enum MockNotificationAuthorization: String, Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
  }

  public enum MockServiceState: String, Equatable, Sendable {
    case available
    case offline
    case malformedResponse
    case reachable
    case unreachable
  }

  public enum MockPetLifecycle: String, Equatable, Sendable {
    case notCreated
    case new
    case active
  }

  public struct MockWardrobeState: Equatable, Sendable {
    public var selectedOutfitID: String?
    public var unlockedOutfitIDs: Set<String>
    public var previewOutfitID: String?

    public init(
      selectedOutfitID: String?,
      unlockedOutfitIDs: Set<String>,
      previewOutfitID: String?
    ) {
      self.selectedOutfitID = selectedOutfitID
      self.unlockedOutfitIDs = unlockedOutfitIDs
      self.previewOutfitID = previewOutfitID
    }
  }

  /// Typed, executable projection of a repository fixture. UI and integration tests consume this
  /// instead of reaching into loosely typed JSON dictionaries.
  public struct MockScenarioRuntime: Sendable {
    public let id: String
    public let displayName: String
    public let clock: TimeTravelClock
    public let hasCompletedOnboarding: Bool
    public let primaryState: MockPrimaryState
    public let healthRequestState: HealthRequestState
    public let notificationAuthorization: MockNotificationAuthorization
    public let healthSnapshot: HealthSnapshot
    public let petLifecycle: MockPetLifecycle
    public let petLevel: Int
    public let wardrobe: MockWardrobeState
    public let aiState: MockServiceState
    public let syncState: MockServiceState
    public let eligibleRandomStoryID: String?
    public let mockBadgeVisible: Bool
    public let initialState: CompanionState
    public let initialLedger: EventLedger

    public init(fixture: ScenarioFixture) throws {
      guard let state = fixture.state.objectValue else {
        throw MockScenarioError.invalidValue("state")
      }
      guard let expectations = fixture.expectations.objectValue else {
        throw MockScenarioError.invalidValue("expectations")
      }

      id = fixture.scenarioID
      displayName = fixture.displayName
      clock = TimeTravelClock(
        anchor: fixture.clock.now,
        timeZoneIdentifier: fixture.clock.timeZone
      )

      let installation = try Self.requiredObject(state, path: "installation")
      hasCompletedOnboarding = installation["hasLaunchedBefore"]?.boolValue == true

      let permissions = try Self.requiredObject(state, path: "permissions")
      healthRequestState = try Self.healthRequestState(
        from: Self.requiredString(permissions, path: "healthRequest")
      )
      let notificationValue = try Self.requiredString(permissions, path: "notifications")
      guard let notifications = MockNotificationAuthorization(rawValue: notificationValue) else {
        throw MockScenarioError.invalidValue("state.permissions.notifications")
      }
      notificationAuthorization = notifications

      let health = try Self.requiredObject(state, path: "health")
      healthSnapshot = try Self.makeHealthSnapshot(
        from: health,
        requestState: healthRequestState,
        now: fixture.clock.now,
        timeZoneIdentifier: fixture.clock.timeZone
      )

      let pet = try Self.requiredObject(state, path: "pet")
      let lifecycleValue = try Self.requiredString(pet, path: "lifecycle")
      guard let lifecycle = MockPetLifecycle(rawValue: lifecycleValue) else {
        throw MockScenarioError.invalidValue("state.pet.lifecycle")
      }
      petLifecycle = lifecycle
      petLevel = max(0, Int(pet["level"]?.numberValue ?? 0))

      let wardrobeObject = try Self.requiredObject(state, path: "wardrobe")
      let selectedOutfitID = wardrobeObject["selectedOutfitID"]?.stringValue
      let unlocked = Set(
        (wardrobeObject["unlockedOutfitIDs"]?.arrayValue ?? []).compactMap(\.stringValue)
      )
      wardrobe = MockWardrobeState(
        selectedOutfitID: selectedOutfitID,
        unlockedOutfitIDs: unlocked,
        previewOutfitID: wardrobeObject["previewOutfitID"]?.stringValue
      )

      let derivedPrimaryState: MockPrimaryState
      if !hasCompletedOnboarding {
        derivedPrimaryState = .onboarding
      } else if petLifecycle == .notCreated || petLifecycle == .new {
        derivedPrimaryState = .petIntroduction
      } else if wardrobe.previewOutfitID != nil {
        derivedPrimaryState = .wardrobe
      } else {
        derivedPrimaryState = .petHome
      }
      let expectedPrimary = try Self.requiredString(expectations, path: "primaryState")
      guard let expectedPrimaryState = MockPrimaryState(rawValue: expectedPrimary) else {
        throw MockScenarioError.invalidValue("expectations.primaryState")
      }
      guard expectedPrimaryState == derivedPrimaryState else {
        throw MockScenarioError.expectationMismatch("primaryState")
      }
      primaryState = derivedPrimaryState

      let services = try Self.requiredObject(state, path: "services")
      aiState = try Self.serviceState(from: Self.requiredString(services, path: "ai"))
      syncState = try Self.serviceState(from: Self.requiredString(services, path: "sync"))
      eligibleRandomStoryID = expectations["eligibleRandomStory"]?.stringValue
      mockBadgeVisible = expectations["mockBadgeVisible"]?.boolValue == true
      guard mockBadgeVisible else {
        throw MockScenarioError.expectationMismatch("mockBadgeVisible")
      }

      let growth = GrowthState(
        vitality: Int(pet["vitality"]?.numberValue ?? 0),
        bond: Int(pet["bond"]?.numberValue ?? 0),
        insight: Int(pet["insight"]?.numberValue ?? 0)
      )
      initialState = CompanionState(
        pet: PetState(equippedOutfitID: selectedOutfitID),
        growth: growth
      )
      if hasCompletedOnboarding {
        let event = EventEnvelope(
          eventID: Self.healthEventID,
          occurredAt: fixture.clock.now,
          source: .mock,
          payload: .healthSnapshotReceived(healthSnapshot)
        )
        initialLedger = try EventLedger(events: [event])
      } else {
        initialLedger = try EventLedger()
      }
    }

    private static let healthEventID = UUID(
      uuidString: "00000000-0000-0000-0000-00000000A001"
    )!

    private static func requiredObject(
      _ object: [String: JSONValue],
      path: String
    ) throws -> [String: JSONValue] {
      guard let value = object[path]?.objectValue else {
        throw MockScenarioError.missingValue(path)
      }
      return value
    }

    private static func requiredString(
      _ object: [String: JSONValue],
      path: String
    ) throws -> String {
      guard let value = object[path]?.stringValue else {
        throw MockScenarioError.missingValue(path)
      }
      return value
    }

    private static func healthRequestState(from value: String) throws -> HealthRequestState {
      switch value {
      case "notRequested": return .notRequested
      case "completed": return .requestCompleted
      case "unavailable": return .unavailable
      default: throw MockScenarioError.invalidValue("state.permissions.healthRequest")
      }
    }

    private static func serviceState(from value: String) throws -> MockServiceState {
      guard let result = MockServiceState(rawValue: value) else {
        throw MockScenarioError.invalidValue("state.services")
      }
      return result
    }

    private static func makeHealthSnapshot(
      from health: [String: JSONValue],
      requestState: HealthRequestState,
      now: Date,
      timeZoneIdentifier: String
    ) throws -> HealthSnapshot {
      let dataState = try requiredString(health, path: "dataState")
      let samples = health["samples"]?.arrayValue?.compactMap(\.objectValue) ?? []
      let availability: HealthDataAvailability
      let freshness: HealthDataFreshness
      switch dataState {
      case "available":
        availability = .available
        freshness = .fresh
      case "partial":
        availability = .partial
        freshness = .fresh
      case "stale":
        availability = samples.isEmpty ? .noData : .partial
        freshness = .stale
      case "noData", "unavailable":
        availability = .noData
        freshness = .noData
      default:
        throw MockScenarioError.invalidValue("state.health.dataState")
      }

      var sleepMinutes = 0
      var hasSleep = false
      var steps: Int?
      var activeMinutes: Int?
      var restingHeartRate: Double?
      var workouts: [WorkoutSummary] = []
      for sample in samples {
        guard let type = sample["type"]?.stringValue else { continue }
        switch type {
        case "sleepAnalysis":
          guard
            let start = try date(sample, key: "start"),
            let end = try date(sample, key: "end")
          else { continue }
          hasSleep = true
          sleepMinutes += max(0, Int(end.timeIntervalSince(start) / 60))
        case "stepCount":
          steps = (steps ?? 0) + Int(sample["value"]?.numberValue ?? 0)
        case "appleExerciseTime":
          activeMinutes = (activeMinutes ?? 0) + Int(sample["value"]?.numberValue ?? 0)
        case "restingHeartRate":
          restingHeartRate = sample["value"]?.numberValue
        case "workout":
          guard let start = try date(sample, key: "start") else { continue }
          let durationSeconds = sample["durationSeconds"]?.numberValue ?? 0
          let activity =
            WorkoutSummary.Activity(
              rawValue: sample["activityType"]?.stringValue ?? "other"
            ) ?? .other
          let activeEnergy = sample["activeEnergy"]?.objectValue?["value"]?.numberValue
          workouts.append(
            WorkoutSummary(
              id: stableUUID(from: sample["id"]?.stringValue ?? "workout"),
              activity: activity,
              startedAt: start,
              durationMinutes: Int(durationSeconds / 60),
              activeEnergyKilocalories: activeEnergy
            )
          )
        default:
          continue
        }
      }

      return HealthSnapshot(
        capturedAt: now,
        timeZoneIdentifier: timeZoneIdentifier,
        freshness: freshness,
        requestState: requestState,
        availability: availability,
        sources: samples.isEmpty ? [] : [HealthFixtures.appleWatch],
        sleepMinutes: hasSleep ? sleepMinutes : nil,
        steps: steps,
        activeMinutes: activeMinutes,
        restingHeartRateBPM: restingHeartRate,
        workouts: workouts
      )
    }

    private static func date(_ object: [String: JSONValue], key: String) throws -> Date? {
      guard let value = object[key]?.stringValue else { return nil }
      guard let date = ISO8601DateFormatter().date(from: value) else {
        throw MockScenarioError.invalidValue("state.health.samples.\(key)")
      }
      return date
    }

    private static func stableUUID(from value: String) -> UUID {
      var bytes = [UInt8](repeating: 0, count: 16)
      for (index, byte) in value.utf8.enumerated() {
        bytes[index % bytes.count] = bytes[index % bytes.count] &+ byte &+ UInt8(index & 0xFF)
      }
      return UUID(
        uuid: (
          bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
          bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
  }

  public struct MockScenarioRun: Sendable {
    public let runtime: MockScenarioRuntime
    public private(set) var clock: TimeTravelClock
    public private(set) var ledger: EventLedger
    public private(set) var state: CompanionState

    private let reducer: CompanionReducer
    private var nextEventSequence: UInt64

    public init(runtime: MockScenarioRuntime, reducer: CompanionReducer = CompanionReducer()) throws
    {
      self.runtime = runtime
      clock = runtime.clock
      ledger = runtime.initialLedger
      self.reducer = reducer
      state = try reducer.replay(ledger.events, from: runtime.initialState)
      nextEventSequence = 2
    }

    public mutating func advance(by interval: TimeInterval) {
      clock.advance(by: interval)
    }

    @discardableResult
    public mutating func interact(kind: String) throws -> EventEnvelope {
      let event = EventEnvelope(
        eventID: sequenceUUID(nextEventSequence),
        occurredAt: clock.now,
        source: .mock,
        payload: .petInteracted(PetInteraction(kind: kind))
      )
      nextEventSequence += 1
      try ledger.append(event)
      try reducer.reduce(&state, event: event)
      return event
    }

    public mutating func replay() throws {
      state = try reducer.replay(ledger.events, from: runtime.initialState)
    }

    private func sequenceUUID(_ sequence: UInt64) -> UUID {
      let suffix = String(format: "%012llX", sequence)
      return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
  }
#endif
