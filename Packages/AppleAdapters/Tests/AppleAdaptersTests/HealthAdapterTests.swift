import Foundation
import Testing

@testable import AppleAdapters

@Suite("Health adapter contract")
struct HealthAdapterTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func requestIsIdempotentAndDoesNotClaimReadAuthorization() async {
    let client = MockHealthDataClient(snapshot: emptySnapshot)
    #expect(await client.requestAccess() == .requestCompleted)
    #expect(await client.requestAccess() == .requestCompleted)
    #expect(await client.requestInvocationCount == 1)
  }

  @Test func snapshotPreservesPerTypeDataAvailability() async throws {
    let sleep = SleepSample(start: now, end: now.addingTimeInterval(3_600), stage: .deep)
    let snapshot = HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(availability: .available, values: [sleep]),
      steps: HealthReading(availability: .noData, values: []),
      restingHeartRate: HealthReading(
        availability: .unavailable(reason: "not reported"),
        values: []
      ),
      workouts: HealthReading(availability: .noData, values: [])
    )
    let client = MockHealthDataClient(requestState: .requestCompleted, snapshot: snapshot)
    let result = try await client.fetchSnapshot(
      in: HealthQueryWindow(start: now.addingTimeInterval(-1), end: now.addingTimeInterval(4_000))
    )
    #expect(result == snapshot)
    #expect(result.steps.availability == .noData)
    #expect(result.restingHeartRate.availability == .unavailable(reason: "not reported"))
  }

  @Test func invalidWindowFailsBeforeFetch() async {
    let client = MockHealthDataClient(snapshot: emptySnapshot)
    await #expect(throws: HealthAdapterError.invalidQueryWindow) {
      try await client.fetchSnapshot(
        in: HealthQueryWindow(start: self.now, end: self.now.addingTimeInterval(-1))
      )
    }
    #expect(await client.fetchInvocationCount == 0)
  }

  @Test func overnightSleepCanBeginBeforeDailyActivity() {
    let window = HealthQueryWindow(
      start: now,
      sleepStart: now.addingTimeInterval(-12 * 3_600),
      end: now.addingTimeInterval(12 * 3_600)
    )

    #expect(window.isValid)
    #expect(window.sleepStart < window.start)
  }

  @Test func sleepCannotBeginAfterDailyActivity() {
    let window = HealthQueryWindow(
      start: now,
      sleepStart: now.addingTimeInterval(1),
      end: now.addingTimeInterval(12 * 3_600)
    )

    #expect(!window.isValid)
  }

  @Test func unavailableFallbackIsNeutral() async throws {
    let client = UnavailableHealthDataClient(reason: "test host")
    #expect(await client.requestAccess() == .unavailable(reason: "test host"))
    let result = try await client.fetchSnapshot(
      in: HealthQueryWindow(start: now, end: now.addingTimeInterval(1))
    )
    #expect(result.sleep.availability == .unavailable(reason: "test host"))
    #expect(result.sleep.values.isEmpty)
  }

  @Test func workoutActivityUsesAStableDomainValue() {
    let source = HealthSampleSource(
      bundleIdentifier: "com.apple.health",
      displayName: "Mock Watch",
      productType: "Watch"
    )
    let workout = WorkoutSample(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      activity: .soccer,
      start: now,
      end: now.addingTimeInterval(2_700),
      durationSeconds: 2_700,
      source: source
    )

    #expect(workout.activity == .soccer)
    #expect(workout.durationSeconds == 2_700)
    #expect(workout.source == source)
  }

  private var emptySnapshot: HealthSnapshot {
    HealthSnapshot(
      capturedAt: now,
      sleep: HealthReading(availability: .noData, values: []),
      steps: HealthReading(availability: .noData, values: []),
      restingHeartRate: HealthReading(availability: .noData, values: []),
      workouts: HealthReading(availability: .noData, values: [])
    )
  }
}
