import Domain
import Foundation

struct TimedPersonalizationSignal: Equatable {
  let evidenceID: String
  let observedAt: Date
  let signal: PersonalizationSignal
}

struct LivePersonalizationEvidenceFactory {
  func make(
    latestSnapshot: HealthSnapshot,
    history: [HealthSnapshot],
    excluding existingEvidenceIDs: Set<String>
  ) -> [TimedPersonalizationSignal] {
    var values: [TimedPersonalizationSignal] = []
    for workout in latestSnapshot.workouts
    where workout.activity != .other {
      let evidenceID = "healthkit-workout-\(workout.id.uuidString.lowercased())"
      guard !existingEvidenceIDs.contains(evidenceID) else { continue }
      values.append(
        TimedPersonalizationSignal(
          evidenceID: evidenceID,
          observedAt: workout.startedAt,
          signal: .verifiedWorkout(
            activity: workout.activity,
            durationMinutes: workout.durationMinutes,
            evidenceID: evidenceID
          )
        )
      )
    }

    let recentHistory = Array(history.suffix(7))
    if let routine = WeeklySleepRoutineAggregate.make(snapshots: recentHistory),
      let firstDay = recentHistory.first?.localDay.rawValue,
      let last = recentHistory.last
    {
      let evidenceID = [
        "healthkit-sleep-routine",
        firstDay,
        last.localDay.rawValue,
        routine.band.rawValue,
        routine.regularity.rawValue,
      ].joined(separator: "-")
      if !existingEvidenceIDs.contains(evidenceID) {
        values.append(
          TimedPersonalizationSignal(
            evidenceID: evidenceID,
            observedAt: last.capturedAt,
            signal: .sleepRoutine(
              band: routine.band,
              regularity: routine.regularity,
              sampleCount: routine.sampleCount,
              evidenceID: evidenceID
            )
          )
        )
      }
    }
    return values.sorted {
      if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
      return $0.evidenceID < $1.evidenceID
    }
  }
}
