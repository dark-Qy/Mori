import AppRuntime
import AppleAdapters
import Domain
import Foundation
import Testing

@Suite("Health runtime bridge")
struct HealthRuntimeTests {
  private let now = Date(timeIntervalSince1970: 1_760_000_000)

  @Test("Sleep stages, steps, workout, and provenance map without inventing values")
  func completeMapping() {
    let source = HealthSampleSource(
      bundleIdentifier: "com.apple.health",
      displayName: "Alice Apple Watch",
      productType: "Watch7,1"
    )
    let adapter = AppleAdapters.HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(
        availability: .available,
        values: [
          SleepSample(
            start: now.addingTimeInterval(-7_200), end: now.addingTimeInterval(-3_600),
            stage: .core, source: source),
          SleepSample(
            start: now.addingTimeInterval(-3_600), end: now, stage: .deep, source: source),
          SleepSample(
            start: now.addingTimeInterval(-7_500), end: now.addingTimeInterval(-7_200),
            stage: .awake, source: source),
        ]
      ),
      steps: HealthReading(
        availability: .available,
        values: [TimedQuantity(start: now.addingTimeInterval(-3_600), end: now, value: 4_210)]
      ),
      restingHeartRate: HealthReading(
        availability: .available,
        values: [TimedQuantity(start: now, end: now, value: 58, source: source)]
      ),
      workouts: HealthReading(
        availability: .available,
        values: [
          WorkoutSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000991")!,
            activity: .soccer,
            start: now.addingTimeInterval(-2_700),
            end: now,
            durationSeconds: 2_700,
            source: source
          )
        ]
      )
    )

    let mapped = HealthSnapshotMapper().map(
      adapter,
      requestState: .requestCompleted,
      timeZone: TimeZone(identifier: "Asia/Shanghai")!
    )

    #expect(mapped.sleepMinutes == 120)
    #expect(mapped.sleepStages?.coreMinutes == 60)
    #expect(mapped.sleepStages?.deepMinutes == 60)
    #expect(mapped.sleepStages?.awakeMinutes == 5)
    #expect(mapped.steps == 4_210)
    #expect(mapped.restingHeartRateBPM == 58)
    #expect(mapped.activeMinutes == 45)
    #expect(mapped.workouts.first?.activity == .soccer)
    #expect(mapped.sources.first?.kind == .appleWatch)
  }

  @Test("No-data snapshot remains neutral")
  func noDataMapping() {
    let empty = emptyAdapterSnapshot
    let mapped = HealthSnapshotMapper().map(
      empty,
      requestState: .requestCompleted,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    #expect(mapped.availability == Domain.HealthDataAvailability.noData)
    #expect(mapped.freshness == .noData)
    #expect(mapped.sleepMinutes == nil)
    #expect(mapped.steps == nil)
    #expect(!mapped.hasAnyMetric)
  }

  @Test("Old samples are stale even when fetched now")
  func oldSamplesAreStale() {
    let oldEnd = now.addingTimeInterval(-48 * 3_600)
    let adapter = AppleAdapters.HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(availability: .noData, values: []),
      steps: HealthReading(
        availability: .available,
        values: [TimedQuantity(start: oldEnd.addingTimeInterval(-600), end: oldEnd, value: 100)]
      ),
      restingHeartRate: HealthReading(availability: .noData, values: []),
      workouts: HealthReading(availability: .noData, values: [])
    )

    let mapped = HealthSnapshotMapper().map(
      adapter,
      requestState: .requestCompleted,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    #expect(mapped.freshness == .stale)
    #expect(mapped.capturedAt == oldEnd)
  }

  @Test("Explicit State of Mind labels map without physiological inference")
  func stateOfMindMapping() {
    let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000992")!
    let adapter = AppleAdapters.HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(availability: .noData, values: []),
      steps: HealthReading(availability: .noData, values: []),
      restingHeartRate: HealthReading(availability: .noData, values: []),
      workouts: HealthReading(availability: .noData, values: []),
      stateOfMind: HealthReading(
        availability: .available,
        values: [
          StateOfMindEntry(
            id: sampleID,
            recordedAt: now.addingTimeInterval(-60),
            valence: -0.7,
            labels: [.stressed, .worried]
          )
        ]
      )
    )

    let mapped = HealthSnapshotMapper().map(
      adapter,
      requestState: .requestCompleted,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    #expect(mapped.latestStateOfMind?.id == sampleID)
    #expect(mapped.latestStateOfMind?.labels == [.stressed, .worried])
    #expect(mapped.latestStateOfMind?.requestsGentleCare == true)
    #expect(mapped.sleepMinutes == nil)
    #expect(mapped.steps == nil)
  }

  @Test("A newer State of Mind entry advances capture time even when physical data exists")
  func stateOfMindAdvancesCaptureTime() {
    let physicalEnd = now.addingTimeInterval(-3_600)
    let stateOfMindDate = now.addingTimeInterval(-60)
    let adapter = AppleAdapters.HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(availability: .noData, values: []),
      steps: HealthReading(
        availability: .available,
        values: [
          TimedQuantity(
            start: physicalEnd.addingTimeInterval(-300),
            end: physicalEnd,
            value: 1_000
          )
        ]
      ),
      restingHeartRate: HealthReading(availability: .noData, values: []),
      workouts: HealthReading(availability: .noData, values: []),
      stateOfMind: HealthReading(
        availability: .available,
        values: [
          StateOfMindEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000993")!,
            recordedAt: stateOfMindDate,
            valence: -0.5,
            labels: [.stressed]
          )
        ]
      )
    )

    let mapped = HealthSnapshotMapper().map(
      adapter,
      requestState: .requestCompleted,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    #expect(mapped.capturedAt == stateOfMindDate)
  }

  @Test("Health event identity changes when only State of Mind changes")
  func stateOfMindChangesEventIdentity() async throws {
    let base = AppleAdapters.HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(availability: .noData, values: []),
      steps: HealthReading(availability: .noData, values: []),
      restingHeartRate: HealthReading(availability: .noData, values: []),
      workouts: HealthReading(availability: .noData, values: [])
    )
    let withStress = AppleAdapters.HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(availability: .noData, values: []),
      steps: HealthReading(availability: .noData, values: []),
      restingHeartRate: HealthReading(availability: .noData, values: []),
      workouts: HealthReading(availability: .noData, values: []),
      stateOfMind: HealthReading(
        availability: .available,
        values: [
          StateOfMindEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000994")!,
            recordedAt: now,
            valence: -0.5,
            labels: [.stressed]
          )
        ]
      )
    )
    let client = MockHealthDataClient(requestState: .requestCompleted, snapshot: base)
    let service = HealthIngestionService(client: client, source: .watch)
    let window = HealthQueryWindow(start: now.addingTimeInterval(-6 * 3_600), end: now)

    let first = try await service.ingest(
      window: window,
      timeZone: TimeZone(secondsFromGMT: 0)!,
      requestAccessIfNeeded: false
    )
    await client.replaceSnapshot(withStress)
    let second = try await service.ingest(
      window: window,
      timeZone: TimeZone(secondsFromGMT: 0)!,
      requestAccessIfNeeded: false
    )

    #expect(first.event.eventID != second.event.eventID)
  }

  @Test("Duplicate sleep stages from multiple sources are counted once")
  func duplicateSleepSamples() {
    let interval = SleepSample(
      start: now.addingTimeInterval(-3_600),
      end: now,
      stage: .deep
    )
    let adapter = AppleAdapters.HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(availability: .available, values: [interval, interval]),
      steps: HealthReading(availability: .noData, values: []),
      restingHeartRate: HealthReading(availability: .noData, values: []),
      workouts: HealthReading(availability: .noData, values: [])
    )

    let mapped = HealthSnapshotMapper().map(
      adapter,
      requestState: .requestCompleted,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    #expect(mapped.sleepMinutes == 60)
  }

  @Test("Partially overlapping sleep stages contribute to exactly one stage")
  func partiallyOverlappingSleepSamples() {
    let adapter = AppleAdapters.HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(
        availability: .available,
        values: [
          SleepSample(
            start: now.addingTimeInterval(-7_200),
            end: now.addingTimeInterval(-3_600),
            stage: .core
          ),
          SleepSample(
            start: now.addingTimeInterval(-5_400),
            end: now,
            stage: .deep
          ),
        ]
      ),
      steps: HealthReading(availability: .noData, values: []),
      restingHeartRate: HealthReading(availability: .noData, values: []),
      workouts: HealthReading(availability: .noData, values: [])
    )

    let mapped = HealthSnapshotMapper().map(
      adapter,
      requestState: .requestCompleted,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    #expect(mapped.sleepMinutes == 120)
    #expect(mapped.sleepStages?.coreMinutes == 30)
    #expect(mapped.sleepStages?.deepMinutes == 90)
  }

  @Test("Awake intervals subtract from overlapping asleep intervals")
  func awakeIntervalsOverrideSleep() {
    let adapter = AppleAdapters.HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(
        availability: .available,
        values: [
          SleepSample(start: now.addingTimeInterval(-3_600), end: now, stage: .core),
          SleepSample(
            start: now.addingTimeInterval(-1_800),
            end: now.addingTimeInterval(-1_200),
            stage: .awake
          ),
        ]
      ),
      steps: HealthReading(availability: .noData, values: []),
      restingHeartRate: HealthReading(availability: .noData, values: []),
      workouts: HealthReading(availability: .noData, values: [])
    )

    let mapped = HealthSnapshotMapper().map(
      adapter,
      requestState: .requestCompleted,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    #expect(mapped.sleepMinutes == 50)
    #expect(mapped.sleepStages?.coreMinutes == 50)
    #expect(mapped.sleepStages?.awakeMinutes == 10)
  }

  @Test("Repeated ingestion of identical input produces the same event identity")
  func ingestionIsIdempotent() async throws {
    let client = MockHealthDataClient(
      requestState: .requestCompleted, snapshot: emptyAdapterSnapshot)
    let service = HealthIngestionService(client: client, source: .watch)
    let window = HealthQueryWindow(start: now.addingTimeInterval(-86_400), end: now)

    let first = try await service.ingest(
      window: window,
      timeZone: TimeZone(secondsFromGMT: 0)!,
      requestAccessIfNeeded: false
    )
    let second = try await service.ingest(
      window: window,
      timeZone: TimeZone(secondsFromGMT: 0)!,
      requestAccessIfNeeded: false
    )

    #expect(first.event == second.event)
  }

  @Test("A changed sleep-stage distribution produces a new event identity")
  func eventIdentityIncludesStageDetails() async throws {
    let start = now.addingTimeInterval(-3_600)
    let coreClient = MockHealthDataClient(
      requestState: .requestCompleted,
      snapshot: AppleAdapters.HealthSnapshot(
        capturedAt: now,
        sleep: HealthReading(
          availability: .available,
          values: [SleepSample(start: start, end: now, stage: .core)]
        ),
        steps: HealthReading(availability: .noData, values: []),
        restingHeartRate: HealthReading(availability: .noData, values: []),
        workouts: HealthReading(availability: .noData, values: [])
      )
    )
    let deepClient = MockHealthDataClient(
      requestState: .requestCompleted,
      snapshot: AppleAdapters.HealthSnapshot(
        capturedAt: now,
        sleep: HealthReading(
          availability: .available,
          values: [SleepSample(start: start, end: now, stage: .deep)]
        ),
        steps: HealthReading(availability: .noData, values: []),
        restingHeartRate: HealthReading(availability: .noData, values: []),
        workouts: HealthReading(availability: .noData, values: [])
      )
    )
    let window = HealthQueryWindow(start: start, end: now)

    let core = try await HealthIngestionService(client: coreClient, source: .watch).ingest(
      window: window,
      timeZone: TimeZone(secondsFromGMT: 0)!,
      requestAccessIfNeeded: false
    )
    let deep = try await HealthIngestionService(client: deepClient, source: .watch).ingest(
      window: window,
      timeZone: TimeZone(secondsFromGMT: 0)!,
      requestAccessIfNeeded: false
    )

    #expect(core.event.eventID != deep.event.eventID)
  }

  private var emptyAdapterSnapshot: AppleAdapters.HealthSnapshot {
    AppleAdapters.HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(availability: .noData, values: []),
      steps: HealthReading(availability: .noData, values: []),
      restingHeartRate: HealthReading(availability: .noData, values: []),
      workouts: HealthReading(availability: .noData, values: [])
    )
  }
}
