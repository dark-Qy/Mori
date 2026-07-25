#if DEBUG
  import Domain
  import Foundation
  import Growth
  import Persistence
  import Rules

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

  public struct MockDailyMoment: Equatable, Sendable {
    public let id: String
    public let timeLabel: String
    public let title: String
    public let body: String
    public let sceneID: String
    public let animationID: String

    public init(
      id: String,
      timeLabel: String,
      title: String,
      body: String,
      sceneID: String,
      animationID: String
    ) {
      self.id = id
      self.timeLabel = timeLabel
      self.title = title
      self.body = body
      self.sceneID = sceneID
      self.animationID = animationID
    }
  }

  public struct MockDailyMomentCollection: Equatable, Sendable {
    public let dayID: String
    public let moments: [MockDailyMoment]

    public init(dayID: String, moments: [MockDailyMoment]) {
      self.dayID = dayID
      self.moments = moments
    }
  }

  public struct MockReactiveSceneSample: Equatable, Sendable {
    public let offsetSeconds: TimeInterval
    public let latitude: Double
    public let longitude: Double
    public let telemetry: MovementTelemetry

    public init(
      offsetSeconds: TimeInterval,
      latitude: Double,
      longitude: Double,
      telemetry: MovementTelemetry
    ) {
      self.offsetSeconds = offsetSeconds
      self.latitude = latitude
      self.longitude = longitude
      self.telemetry = telemetry
    }
  }

  public struct MockReactiveSceneTimeline: Equatable, Sendable {
    public let loopDurationSeconds: TimeInterval
    public let samples: [MockReactiveSceneSample]

    public init(
      loopDurationSeconds: TimeInterval,
      samples: [MockReactiveSceneSample]
    ) {
      self.loopDurationSeconds = loopDurationSeconds
      self.samples = samples
    }

    public func sample(at elapsedSeconds: TimeInterval) -> MockReactiveSceneSample {
      let elapsed = elapsedSeconds.truncatingRemainder(dividingBy: loopDurationSeconds)
      return samples.last(where: { $0.offsetSeconds <= elapsed }) ?? samples[0]
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
    public let healthSnapshots: [HealthSnapshot]
    public let healthSnapshot: HealthSnapshot
    public let personalHealthTrend: PersonalHealthTrend?
    public let reactiveSceneTimeline: MockReactiveSceneTimeline?
    public let petLifecycle: MockPetLifecycle
    public let petLevel: Int
    public let characterID: String
    public let dailyMomentCollection: MockDailyMomentCollection?
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
      let snapshots = try Self.makeHealthSnapshots(
        from: health,
        requestState: healthRequestState,
        now: fixture.clock.now,
        timeZoneIdentifier: fixture.clock.timeZone
      )
      healthSnapshots = snapshots
      healthSnapshot = snapshots[snapshots.count - 1]
      if snapshots.count > 1 {
        let trend = PersonalTrendAnalyzer().analyze(snapshots, at: fixture.clock.now)
        try Self.validateTrendExpectation(expectations["trend"]?.objectValue, against: trend)
        personalHealthTrend = trend
      } else {
        personalHealthTrend = nil
      }
      reactiveSceneTimeline = try Self.makeReactiveSceneTimeline(from: state["reactiveScene"])

      let pet = try Self.requiredObject(state, path: "pet")
      let lifecycleValue = try Self.requiredString(pet, path: "lifecycle")
      guard let lifecycle = MockPetLifecycle(rawValue: lifecycleValue) else {
        throw MockScenarioError.invalidValue("state.pet.lifecycle")
      }
      petLifecycle = lifecycle
      petLevel = max(0, Int(pet["level"]?.numberValue ?? 0))
      characterID = pet["characterID"]?.stringValue ?? "penguin"
      guard Self.isValidVisualIdentifier(characterID) else {
        throw MockScenarioError.invalidValue("state.pet.characterID")
      }
      dailyMomentCollection = try Self.makeDailyMomentCollection(
        from: state["dailyMoments"],
        expectedDayID: Self.localDayID(
          for: fixture.clock.now,
          timeZoneIdentifier: fixture.clock.timeZone
        )
      )

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
      let derivedEligibleRandomStoryID =
        SoccerSideStoryRule().qualifyingWorkout(in: healthSnapshot) == nil
        ? nil : "lost_ball"
      guard expectations["eligibleRandomStory"]?.stringValue == derivedEligibleRandomStoryID else {
        throw MockScenarioError.expectationMismatch("eligibleRandomStory")
      }
      eligibleRandomStoryID = derivedEligibleRandomStoryID
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
        pet: PetState(
          equippedOutfitID: selectedOutfitID,
          lastInteractionAt: try Self.date(pet, key: "lastInteractionAt")
        ),
        growth: growth
      )
      if hasCompletedOnboarding {
        let events = healthSnapshots.enumerated().map { index, snapshot in
          EventEnvelope(
            eventID: Self.healthEventID(for: index),
            occurredAt: snapshot.capturedAt,
            source: .mock,
            payload: .healthSnapshotReceived(snapshot)
          )
        }
        initialLedger = try EventLedger(events: events)
      } else {
        initialLedger = try EventLedger()
      }
    }

    private static func healthEventID(for index: Int) -> UUID {
      let suffix = String(format: "%012llX", UInt64(0xA001 + index))
      return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }

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

    private static func makeDailyMomentCollection(
      from value: JSONValue?,
      expectedDayID: String
    ) throws -> MockDailyMomentCollection? {
      guard let value else { return nil }
      guard
        let object = value.objectValue,
        let dayID = object["dayID"]?.stringValue,
        dayID == expectedDayID,
        let values = object["moments"]?.arrayValue,
        (2...8).contains(values.count)
      else {
        throw MockScenarioError.invalidValue("state.dailyMoments")
      }

      let allowedAnimations: Set<String> = [
        "idle_curious",
        "idle_lively",
        "idle_resting",
        "story_reaction",
      ]
      var moments: [MockDailyMoment] = []
      var identifiers: Set<String> = []
      for (index, value) in values.enumerated() {
        guard
          let moment = value.objectValue,
          let id = moment["id"]?.stringValue,
          let timeLabel = moment["timeLabel"]?.stringValue,
          let title = moment["title"]?.stringValue,
          let body = moment["body"]?.stringValue,
          let sceneID = moment["sceneID"]?.stringValue,
          let animationID = moment["animationID"]?.stringValue,
          Self.isValidVisualIdentifier(id),
          Self.isValidVisualIdentifier(sceneID),
          allowedAnimations.contains(animationID),
          timeLabel.isEmpty == false,
          title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
          body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
          identifiers.insert(id).inserted
        else {
          throw MockScenarioError.invalidValue(
            "state.dailyMoments.moments[\(index)]"
          )
        }
        moments.append(
          MockDailyMoment(
            id: id,
            timeLabel: timeLabel,
            title: title,
            body: body,
            sceneID: sceneID,
            animationID: animationID
          )
        )
      }
      return MockDailyMomentCollection(dayID: dayID, moments: moments)
    }

    private static func isValidVisualIdentifier(_ value: String) -> Bool {
      value.isEmpty == false
        && value.unicodeScalars.count <= 64
        && value.unicodeScalars.allSatisfy {
          $0.isASCII
            && (CharacterSet.alphanumerics.contains($0)
              || $0 == "_"
              || $0 == "-")
        }
    }

    private static func localDayID(
      for date: Date,
      timeZoneIdentifier: String
    ) -> String {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
      let components = calendar.dateComponents([.year, .month, .day], from: date)
      return String(
        format: "%04d-%02d-%02d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0
      )
    }

    private static func makeReactiveSceneTimeline(
      from value: JSONValue?
    ) throws -> MockReactiveSceneTimeline? {
      guard let value else { return nil }
      guard let object = value.objectValue else {
        throw MockScenarioError.invalidValue("state.reactiveScene")
      }
      guard
        let loopDurationSeconds = object["loopDurationSeconds"]?.numberValue,
        loopDurationSeconds >= 4,
        loopDurationSeconds <= 120,
        let sampleValues = object["samples"]?.arrayValue,
        (4...16).contains(sampleValues.count)
      else {
        throw MockScenarioError.invalidValue("state.reactiveScene")
      }

      var samples: [MockReactiveSceneSample] = []
      for (index, value) in sampleValues.enumerated() {
        guard
          let sample = value.objectValue,
          let offsetSeconds = sample["offsetSeconds"]?.numberValue,
          let latitude = sample["latitude"]?.numberValue,
          let longitude = sample["longitude"]?.numberValue,
          let speed = sample["speedMetersPerSecond"]?.numberValue,
          let heartRate = sample["heartRateBPM"]?.numberValue,
          offsetSeconds >= 0,
          offsetSeconds < loopDurationSeconds,
          (-90...90).contains(latitude),
          (-180...180).contains(longitude),
          (0...15).contains(speed),
          (30...240).contains(heartRate)
        else {
          throw MockScenarioError.invalidValue(
            "state.reactiveScene.samples[\(index)]"
          )
        }
        samples.append(
          MockReactiveSceneSample(
            offsetSeconds: offsetSeconds,
            latitude: latitude,
            longitude: longitude,
            telemetry: MovementTelemetry(
              speedMetersPerSecond: speed,
              heartRateBPM: heartRate
            )
          )
        )
      }
      guard samples.first?.offsetSeconds == 0 else {
        throw MockScenarioError.invalidValue("state.reactiveScene.samples[0].offsetSeconds")
      }
      guard
        zip(samples, samples.dropFirst()).allSatisfy({
          $0.offsetSeconds < $1.offsetSeconds
        })
      else {
        throw MockScenarioError.invalidValue("state.reactiveScene.samples.offsetSeconds")
      }
      return MockReactiveSceneTimeline(
        loopDurationSeconds: loopDurationSeconds,
        samples: samples
      )
    }

    private static func makeHealthSnapshots(
      from health: [String: JSONValue],
      requestState: HealthRequestState,
      now: Date,
      timeZoneIdentifier: String
    ) throws -> [HealthSnapshot] {
      guard let dailyValues = health["dailySnapshots"]?.arrayValue else {
        return [
          try makeHealthSnapshot(
            from: health,
            requestState: requestState,
            now: now,
            timeZoneIdentifier: timeZoneIdentifier
          )
        ]
      }
      guard !dailyValues.isEmpty, dailyValues.count <= 60 else {
        throw MockScenarioError.invalidValue("state.health.dailySnapshots")
      }
      guard health["samples"]?.arrayValue?.isEmpty != false else {
        throw MockScenarioError.invalidValue("state.health.dailySnapshots cannot accompany samples")
      }

      let defaultDataState = try requiredString(health, path: "dataState")
      var snapshots: [HealthSnapshot] = []
      for (index, value) in dailyValues.enumerated() {
        guard let daily = value.objectValue else {
          throw MockScenarioError.invalidValue("state.health.dailySnapshots[\(index)]")
        }
        snapshots.append(
          try makeDailyHealthSnapshot(
            from: daily,
            defaultDataState: defaultDataState,
            requestState: requestState,
            timeZoneIdentifier: timeZoneIdentifier,
            index: index
          )
        )
      }
      snapshots.sort { $0.capturedAt < $1.capturedAt }
      guard snapshots.allSatisfy({ $0.capturedAt <= now }) else {
        throw MockScenarioError.invalidValue("state.health.dailySnapshots.capturedAt")
      }
      guard Set(snapshots.map(\.localDay)).count == snapshots.count else {
        throw MockScenarioError.invalidValue("state.health.dailySnapshots.localDay")
      }
      return snapshots
    }

    private static func makeHealthSnapshot(
      from health: [String: JSONValue],
      requestState: HealthRequestState,
      now: Date,
      timeZoneIdentifier: String
    ) throws -> HealthSnapshot {
      let dataState = try requiredString(health, path: "dataState")
      let samples = health["samples"]?.arrayValue?.compactMap(\.objectValue) ?? []
      let (availability, freshness) = try healthStates(
        dataState: dataState,
        hasData: !samples.isEmpty,
        path: "state.health.dataState"
      )

      var sleepMinutes = 0
      var hasSleep = false
      var steps: Int?
      var activeMinutes: Int?
      var restingHeartRate: Double?
      var workouts: [WorkoutSummary] = []
      var stateOfMindSamples: [StateOfMindSample] = []
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
        case "stateOfMind":
          guard let recordedAt = try date(sample, key: "recordedAt") else { continue }
          let labels = Set(
            (sample["labels"]?.arrayValue ?? []).compactMap(\.stringValue).map {
              StateOfMindLabel(rawValue: $0) ?? .other
            }
          )
          stateOfMindSamples.append(
            StateOfMindSample(
              id: stableUUID(from: sample["id"]?.stringValue ?? "state-of-mind"),
              recordedAt: recordedAt,
              valence: sample["valence"]?.numberValue ?? 0,
              labels: labels
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
        workouts: workouts,
        stateOfMindSamples: stateOfMindSamples
      )
    }

    private static func makeDailyHealthSnapshot(
      from daily: [String: JSONValue],
      defaultDataState: String,
      requestState: HealthRequestState,
      timeZoneIdentifier: String,
      index: Int
    ) throws -> HealthSnapshot {
      guard let capturedAt = try date(daily, key: "capturedAt") else {
        throw MockScenarioError.missingValue("state.health.dailySnapshots[\(index)].capturedAt")
      }
      let dataState = daily["dataState"]?.stringValue ?? defaultDataState
      let sleepMinutes = daily["sleepMinutes"]?.numberValue.map(Int.init)
      let steps = daily["steps"]?.numberValue.map(Int.init)
      let activeMinutes = daily["activeMinutes"]?.numberValue.map(Int.init)
      let restingHeartRate = daily["restingHeartRate"]?.numberValue
      let sleepWindowStart = try date(daily, key: "sleepWindowStart")
      let sleepWindowEnd = try date(daily, key: "sleepWindowEnd")
      let workoutValues = daily["workouts"]?.arrayValue ?? []
      var workouts: [WorkoutSummary] = []
      for (workoutIndex, value) in workoutValues.enumerated() {
        guard let workout = value.objectValue else {
          throw MockScenarioError.invalidValue(
            "state.health.dailySnapshots[\(index)].workouts[\(workoutIndex)]"
          )
        }
        guard let startedAt = try date(workout, key: "startedAt") else {
          throw MockScenarioError.missingValue(
            "state.health.dailySnapshots[\(index)].workouts[\(workoutIndex)].startedAt"
          )
        }
        guard
          let activity = WorkoutSummary.Activity(
            rawValue: workout["activityType"]?.stringValue ?? "other"
          )
        else {
          throw MockScenarioError.invalidValue(
            "state.health.dailySnapshots[\(index)].workouts[\(workoutIndex)].activityType"
          )
        }
        workouts.append(
          WorkoutSummary(
            id: stableUUID(
              from: workout["id"]?.stringValue ?? "daily-\(index)-workout-\(workoutIndex)"
            ),
            activity: activity,
            startedAt: startedAt,
            durationMinutes: Int(workout["durationMinutes"]?.numberValue ?? 0),
            activeEnergyKilocalories: workout["activeEnergyKilocalories"]?.numberValue
          )
        )
      }

      let hasData =
        sleepMinutes != nil || steps != nil || activeMinutes != nil || restingHeartRate != nil
        || !workouts.isEmpty
      let (availability, freshness) = try healthStates(
        dataState: dataState,
        hasData: hasData,
        path: "state.health.dailySnapshots[\(index)].dataState"
      )
      return HealthSnapshot(
        capturedAt: capturedAt,
        timeZoneIdentifier: timeZoneIdentifier,
        freshness: freshness,
        requestState: requestState,
        availability: availability,
        sources: hasData ? [HealthFixtures.appleWatch] : [],
        sleepMinutes: sleepMinutes,
        sleepWindowStart: sleepWindowStart,
        sleepWindowEnd: sleepWindowEnd,
        steps: steps,
        activeMinutes: activeMinutes,
        restingHeartRateBPM: restingHeartRate,
        workouts: workouts
      )
    }

    private static func healthStates(
      dataState: String,
      hasData: Bool,
      path: String
    ) throws -> (HealthDataAvailability, HealthDataFreshness) {
      switch dataState {
      case "available":
        return (.available, .fresh)
      case "partial":
        return (.partial, .fresh)
      case "stale":
        return (hasData ? .partial : .noData, .stale)
      case "noData", "unavailable":
        return (.noData, .noData)
      default:
        throw MockScenarioError.invalidValue(path)
      }
    }

    private static func validateTrendExpectation(
      _ expectation: [String: JSONValue]?,
      against trend: PersonalHealthTrend
    ) throws {
      guard let expectation else { return }
      if let expected = expectation["recentDayCount"]?.numberValue,
        trend.recentDays.count != Int(expected)
      {
        throw MockScenarioError.expectationMismatch("trend.recentDayCount")
      }
      if let expected = expectation["usableBaselineDayCount"]?.numberValue,
        trend.usableBaselineDayCount != Int(expected)
      {
        throw MockScenarioError.expectationMismatch("trend.usableBaselineDayCount")
      }
      for metric in TrendMetric.allCases {
        guard let rawStatus = expectation[metric.rawValue]?.stringValue else { continue }
        guard let expectedStatus = PersonalTrendStatus(rawValue: rawStatus) else {
          throw MockScenarioError.invalidValue("expectations.trend.\(metric.rawValue)")
        }
        guard
          trend.observations.first(where: { $0.metric == metric })?.status == expectedStatus
        else {
          throw MockScenarioError.expectationMismatch("trend.\(metric.rawValue)")
        }
      }
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
      nextEventSequence = UInt64(ledger.events.count + 1)
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
