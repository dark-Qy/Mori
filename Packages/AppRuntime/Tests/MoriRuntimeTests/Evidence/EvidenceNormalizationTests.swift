import AppleAdapters
import Foundation
import MoriDomain
import MoriRuntime
import Testing

@Suite("Mori evidence normalization")
struct EvidenceNormalizationTests {
  @Test("Health normalization persists only bounded step and merged sleep summaries")
  func healthSummary() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let profile = realProfile()
    let sleepStart = now.addingTimeInterval(-8 * 3_600)
    let snapshot = AppleAdapters.HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(
        availability: .available,
        values: [
          SleepSample(
            start: sleepStart,
            end: sleepStart.addingTimeInterval(4 * 3_600),
            stage: .core
          ),
          SleepSample(
            start: sleepStart.addingTimeInterval(3 * 3_600),
            end: sleepStart.addingTimeInterval(6 * 3_600),
            stage: .deep
          ),
          SleepSample(
            start: sleepStart.addingTimeInterval(6 * 3_600),
            end: sleepStart.addingTimeInterval(7 * 3_600),
            stage: .awake
          ),
        ]
      ),
      steps: HealthReading(
        availability: .available,
        values: [
          TimedQuantity(
            start: now.addingTimeInterval(-60),
            end: now,
            value: 3_000
          ),
          TimedQuantity(
            start: now.addingTimeInterval(-60),
            end: now,
            value: 250
          ),
        ]
      ),
      restingHeartRate: HealthReading(availability: .noData, values: []),
      workouts: HealthReading(availability: .noData, values: [])
    )

    let batch = MoriEvidenceNormalizer().normalizeHealth(
      snapshot,
      profile: profile,
      admission: .companion(
        sensingEpoch(),
        activeSince: sleepStart.addingTimeInterval(-60)
      )
    )

    #expect(batch.displayFacts.count == 2)
    #expect(batch.companionFacts.count == 2)
    #expect(batch.displayFacts.map(\.value).contains(.stepTotal(3_250)))
    #expect(batch.displayFacts.map(\.value).contains(.sleepDuration(6 * 3_600)))
    #expect(
      batch.displayFacts.allSatisfy { $0.authorization == .displayOnly }
    )
    #expect(
      batch.companionFacts.allSatisfy {
        $0.authorization == .companion(sensingEpoch())
          && $0.validate(in: profile) == nil
      }
    )
  }

  @Test("Unavailable malformed and raw-only health input stays neutral")
  func neutralHealth() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = AppleAdapters.HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(availability: .unavailable(reason: "denied"), values: []),
      steps: HealthReading(
        availability: .available,
        values: [
          TimedQuantity(start: now, end: now, value: -.infinity)
        ]
      ),
      restingHeartRate: HealthReading(availability: .available, values: []),
      workouts: HealthReading(availability: .available, values: [])
    )

    #expect(
      MoriEvidenceNormalizer().normalizeHealth(
        snapshot,
        profile: realProfile(),
        admission: .displayOnly
      ).facts.isEmpty
    )
  }

  @Test("Health captured after re-enable never backfills the disabled interval")
  func healthNoBackfill() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let activeSince = now.addingTimeInterval(-5 * 60)
    let profile = realProfile()
    let snapshot = AppleAdapters.HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(
        availability: .available,
        values: [
          SleepSample(
            start: now.addingTimeInterval(-8 * 3_600),
            end: now.addingTimeInterval(-2 * 3_600),
            stage: .core
          )
        ]
      ),
      steps: HealthReading(
        availability: .available,
        values: [
          TimedQuantity(
            start: now.addingTimeInterval(-8 * 3_600),
            end: activeSince,
            value: 3_000
          ),
          TimedQuantity(
            start: activeSince,
            end: now,
            value: 250
          ),
        ]
      ),
      restingHeartRate: HealthReading(availability: .noData, values: []),
      workouts: HealthReading(availability: .noData, values: [])
    )

    let batch = MoriEvidenceNormalizer().normalizeHealth(
      snapshot,
      profile: profile,
      admission: .companion(sensingEpoch(), activeSince: activeSince)
    )

    #expect(batch.displayFacts.map(\.value).contains(.stepTotal(3_250)))
    #expect(batch.displayFacts.map(\.value).contains(.sleepDuration(6 * 3_600)))
    #expect(batch.companionFacts.map(\.value) == [.stepTotal(250)])
  }

  @Test("Motion and approved place emit only broad closed facts")
  func minimizedAdapters() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let normalizer = MoriEvidenceNormalizer()
    let profile = realProfile()

    let motion = try #require(
      normalizer.normalizeMotion(
        BroadMotionObservation(
          activity: .walking,
          confidence: .medium,
          observedAt: now
        ),
        profile: profile,
        admission: .companion(
          sensingEpoch(),
          activeSince: now.addingTimeInterval(-60)
        )
      )
    )
    let place = try #require(
      normalizer.normalizeApprovedPlace(
        AppleAdapters.ApprovedPlaceObservation(
          category: .park,
          presence: .entered,
          observedAt: now
        ),
        profile: profile,
        admission: .companion(
          sensingEpoch(),
          activeSince: now.addingTimeInterval(-60)
        )
      )
    )

    #expect(motion.value == .broadMotion(.walking))
    #expect(place.value == .approvedPlaceCategory(.park))
    #expect(motion.provenance == .motionClassifier)
    #expect(place.provenance == .coarsePlaceClassifier)
    #expect(
      normalizer.normalizeApprovedPlace(
        AppleAdapters.ApprovedPlaceObservation(
          category: .park,
          presence: .exited,
          observedAt: now
        ),
        profile: profile,
        admission: .companion(
          sensingEpoch(),
          activeSince: now.addingTimeInterval(-60)
        )
      ) == nil
    )
    #expect(
      normalizer.normalizeMotion(
        BroadMotionObservation(
          activity: .walking,
          confidence: .low,
          observedAt: now
        ),
        profile: profile,
        admission: .companion(
          sensingEpoch(),
          activeSince: now.addingTimeInterval(-60)
        )
      ) == nil
    )
  }

  @Test("Display-only capture cannot later authorize companionship")
  func noAuthorizationUpgrade() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let profile = realProfile()
    let normalizer = MoriEvidenceNormalizer()
    let display = try #require(
      normalizer.normalizeForegroundInteraction(
        observedAt: now,
        profile: profile,
        admission: .displayOnly
      )
    )
    let companion = try #require(
      normalizer.normalizeForegroundInteraction(
        observedAt: now.addingTimeInterval(1),
        profile: profile,
        admission: .companion(
          sensingEpoch(counter: 31),
          activeSince: now.addingTimeInterval(0.5)
        )
      )
    )

    #expect(display.authorization == .displayOnly)
    #expect(display.authorizesCompanionUse(in: sensingEpoch(counter: 31)) == false)
    #expect(companion.authorization == .companion(sensingEpoch(counter: 31)))
    #expect(display.header.recordID != companion.header.recordID)
  }

  @Test("Evidence identity includes the complete value and deletion fence")
  func completeEvidenceIdentity() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let normalizer = MoriEvidenceNormalizer()
    let profile = realProfile()
    let admission = EvidenceAdmissionMode.companion(
      sensingEpoch(),
      activeSince: now.addingTimeInterval(-60)
    )
    let walking = try #require(
      normalizer.normalizeMotion(
        BroadMotionObservation(
          activity: .walking,
          confidence: .high,
          observedAt: now
        ),
        profile: profile,
        admission: admission
      )
    )
    let running = try #require(
      normalizer.normalizeMotion(
        BroadMotionObservation(
          activity: .running,
          confidence: .high,
          observedAt: now
        ),
        profile: profile,
        admission: admission
      )
    )
    let afterDeletion = RuntimeProfile(
      id: profile.id,
      epoch: profile.epoch,
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("later-delete"),
        revision: revision(2)
      ),
      source: profile.source
    )
    let walkingAfterDeletion = try #require(
      normalizer.normalizeMotion(
        BroadMotionObservation(
          activity: .walking,
          confidence: .high,
          observedAt: now
        ),
        profile: afterDeletion,
        admission: admission
      )
    )

    #expect(walking.header.recordID != running.header.recordID)
    #expect(walking.header.recordID != walkingAfterDeletion.header.recordID)
  }

  @Test("Mock facts use deterministic provenance and stable identity")
  func mockIdentity() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let profile = mockProfile()
    let normalizer = MoriEvidenceNormalizer()
    let observation = BroadMotionObservation(
      activity: .stationary,
      confidence: .high,
      observedAt: now
    )
    let first = try #require(
      normalizer.normalizeMotion(
        observation,
        profile: profile,
        admission: .companion(
          sensingEpoch(),
          activeSince: now.addingTimeInterval(-60)
        )
      )
    )
    let second = try #require(
      normalizer.normalizeMotion(
        observation,
        profile: profile,
        admission: .companion(
          sensingEpoch(),
          activeSince: now.addingTimeInterval(-60)
        )
      )
    )

    #expect(first == second)
    #expect(first.provenance == .deterministicMock)
    #expect(first.validate(in: profile) == nil)
  }
}

@Suite("Companion health evidence windows")
struct CompanionHealthEvidenceReaderTests {
  @Test("Midday activation queries a post-enable step delta")
  func middayActivationUsesSeparateWindow() async throws {
    let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
    let activeSince = dayStart.addingTimeInterval(12 * 3_600)
    let end = activeSince.addingTimeInterval(30 * 60)
    let client = WindowedHealthClient(
      displayStart: dayStart,
      displaySteps: 4_000,
      companionSteps: 1_000
    )
    let reader = CompanionHealthEvidenceReader(client: client)

    let batch = try await reader.read(
      in: HealthQueryWindow(
        start: dayStart,
        sleepStart: dayStart.addingTimeInterval(-12 * 3_600),
        end: end
      ),
      profile: realProfile(),
      admission: .companion(
        sensingEpoch(),
        activeSince: activeSince
      )
    )

    #expect(batch.displayFacts.map(\.value) == [.stepTotal(4_000)])
    #expect(batch.companionFacts.map(\.value) == [.stepTotal(1_000)])
    let windows = await client.requestedWindows()
    #expect(windows.count == 2)
    #expect(windows[0].start == dayStart)
    #expect(windows[1].start == activeSince)
    #expect(windows[1].sleepStart == activeSince)
  }
}

private actor WindowedHealthClient: HealthDataClient {
  private let displayStart: Date
  private let displaySteps: Double
  private let companionSteps: Double
  private var windows: [HealthQueryWindow] = []

  init(
    displayStart: Date,
    displaySteps: Double,
    companionSteps: Double
  ) {
    self.displayStart = displayStart
    self.displaySteps = displaySteps
    self.companionSteps = companionSteps
  }

  func accessRequestState() -> HealthAccessRequestState {
    .requestCompleted
  }

  func requestAccess() -> HealthAccessRequestState {
    .requestCompleted
  }

  func fetchSnapshot(in window: HealthQueryWindow) throws -> AppleAdapters.HealthSnapshot {
    guard window.isValid else {
      throw HealthAdapterError.invalidQueryWindow
    }
    windows.append(window)
    let total = window.start == displayStart ? displaySteps : companionSteps
    return AppleAdapters.HealthSnapshot(
      capturedAt: window.end,
      sleep: HealthReading(availability: .noData, values: []),
      steps: HealthReading(
        availability: .available,
        values: [
          TimedQuantity(
            start: window.start,
            end: window.end,
            value: total
          )
        ]
      ),
      restingHeartRate: HealthReading(availability: .noData, values: []),
      workouts: HealthReading(availability: .noData, values: [])
    )
  }

  func requestedWindows() -> [HealthQueryWindow] {
    windows
  }
}

private func revision(_ counter: UInt64, device: String = "iphone") -> LamportRevision {
  LamportRevision(counter: counter, originDeviceID: device)
}

private func sensingEpoch(counter: UInt64 = 30) -> SensingEpoch {
  SensingEpoch(revision(counter, device: "watch"))
}

private func deletionEpoch() -> DeletionEpoch {
  DeletionEpoch(
    requestID: DeletionRequestID("initial-delete"),
    revision: revision(1)
  )
}

private func realProfile() -> RuntimeProfile {
  RuntimeProfile(
    id: ProfileID("real"),
    epoch: ProfileEpoch(revision(1)),
    deletionEpoch: deletionEpoch(),
    source: .real
  )
}

private func mockProfile() -> RuntimeProfile {
  let epoch = ProfileEpoch(revision(2))
  return RuntimeProfile(
    id: ProfileID("mock-profile"),
    epoch: epoch,
    deletionEpoch: deletionEpoch(),
    source: .mock(
      scenarioID: MockScenarioID("ordinary-day"),
      selectionEpoch: epoch
    )
  )
}
