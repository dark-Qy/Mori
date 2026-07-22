import Domain
import Foundation

public enum HealthFixtures {
  public static let appleWatch = HealthSource(
    identifier: "fixture.apple-watch",
    displayName: "Apple Watch (Fixture)",
    kind: .mock
  )

  public static func noData(at date: Date) -> HealthSnapshot {
    HealthSnapshot(
      capturedAt: date,
      freshness: .noData,
      requestState: .requestCompleted,
      availability: .noData
    )
  }

  public static func unavailable(at date: Date) -> HealthSnapshot {
    HealthSnapshot(
      capturedAt: date,
      freshness: .noData,
      requestState: .unavailable,
      availability: .noData
    )
  }

  public static func normal(at date: Date) -> HealthSnapshot {
    HealthSnapshot(
      capturedAt: date,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      sources: [appleWatch],
      sleepMinutes: 450,
      steps: 8_500,
      activeMinutes: 35,
      restingHeartRateBPM: 61
    )
  }

  public static func lowSleep(at date: Date) -> HealthSnapshot {
    HealthSnapshot(
      capturedAt: date,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .partial,
      sources: [appleWatch],
      sleepMinutes: 330,
      steps: 4_200,
      activeMinutes: 18
    )
  }

  public static func soccer(at date: Date, workoutID: UUID) -> HealthSnapshot {
    HealthSnapshot(
      capturedAt: date,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      sources: [appleWatch],
      sleepMinutes: 430,
      steps: 9_000,
      activeMinutes: 55,
      workouts: [
        WorkoutSummary(
          id: workoutID,
          activity: .soccer,
          startedAt: date.addingTimeInterval(-3_600),
          durationMinutes: 45
        )
      ]
    )
  }
}
