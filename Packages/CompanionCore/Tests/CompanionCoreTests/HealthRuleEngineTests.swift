import Domain
import Foundation
import MockKit
import Rules
import Testing

@Suite("Phase 1 health rules")
struct HealthRuleEngineTests {
  @Test("Only an explicit fresh soccer workout can qualify the soccer side story")
  func soccerEligibilityUsesWorkoutTypeAndDuration() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let shortSoccer = WorkoutSummary(
      id: UUID(), activity: .soccer, startedAt: now, durationMinutes: 10)
    let longRun = WorkoutSummary(
      id: UUID(), activity: .running, startedAt: now, durationMinutes: 60)
    let qualifying = WorkoutSummary(
      id: UUID(), activity: .soccer, startedAt: now, durationMinutes: 25)
    let rule = SoccerSideStoryRule(minimumDurationMinutes: 20)

    let snapshot = HealthSnapshot(
      capturedAt: now,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      workouts: [shortSoccer, longRun, qualifying]
    )
    #expect(rule.qualifyingWorkout(in: snapshot)?.id == qualifying.id)

    let unavailable = HealthSnapshot(
      capturedAt: now,
      freshness: .fresh,
      requestState: .notRequested,
      availability: .available,
      workouts: [qualifying]
    )
    #expect(rule.qualifyingWorkout(in: unavailable) == nil)
  }
  private let now = Date(timeIntervalSince1970: 1_750_000_000)
  private let engine = HealthRuleEngine()

  @Test("No data remains neutral and never invents a condition")
  func noDataIsNeutral() {
    let decision = engine.evaluate(HealthFixtures.noData(at: now), at: now)

    #expect(decision.theme == .neutral)
    #expect(decision.petMood == .neutral)
    #expect(decision.vitalityAward == 0)
    #expect(decision.trace.steps.count == 1)
    #expect(decision.trace.steps[0].outcome == .skipped)
    #expect(decision.trace.steps[0].explanation.contains("No usable"))
  }

  @Test(
    "Unavailable and stale snapshots cannot inform rules",
    arguments: [
      HealthSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
        freshness: .fresh,
        requestState: .unavailable,
        availability: .noData,
        sleepMinutes: 120,
        steps: 20_000
      ),
      HealthSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
        freshness: .stale,
        requestState: .requestCompleted,
        availability: .available,
        sleepMinutes: 120,
        steps: 20_000
      ),
    ])
  func unusableSnapshotsAreNeutral(snapshot: HealthSnapshot) {
    let decision = engine.evaluate(snapshot, at: now)

    #expect(decision.theme == .neutral)
    #expect(decision.vitalityAward == 0)
  }

  @Test("Freshness labels cannot override capture time")
  func staleCaptureTimeIsNeutral() {
    let old = HealthSnapshot(
      capturedAt: now.addingTimeInterval(-(37 * 60 * 60)),
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      steps: 20_000
    )
    let tooFarInFuture = HealthSnapshot(
      capturedAt: now.addingTimeInterval(6 * 60),
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      steps: 20_000
    )

    #expect(engine.evaluate(old, at: now).theme == .neutral)
    #expect(engine.evaluate(tooFarInFuture, at: now).theme == .neutral)
  }

  @Test("Local days validate dates and time-zone settlement")
  func localDayValidation() {
    #expect(LocalDay(rawValue: "2025-02-30") == nil)
    #expect(LocalDay(rawValue: "2025-6-15") == nil)

    let shanghai = HealthSnapshot(
      capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
      timeZoneIdentifier: "Asia/Shanghai",
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      steps: 8_000
    )
    #expect(shanghai.localDay.rawValue == "2025-06-15")
    #expect(shanghai.hasConsistentSettlementDay)
  }

  @Test("Low-sleep threshold is strict and exact boundary is not low")
  func lowSleepThreshold() {
    let below = snapshot(sleep: 359, steps: 5_000, activeMinutes: 20)
    let boundary = snapshot(sleep: 360, steps: 5_000, activeMinutes: 20)

    #expect(engine.evaluate(below, at: now).theme == .recovery)
    #expect(engine.evaluate(boundary, at: now).theme != .recovery)
  }

  @Test("Activity thresholds award vitality but respect evaluation cap")
  func activityThresholdsAndCap() {
    let below = snapshot(sleep: 419, steps: 7_999, activeMinutes: 29)
    let exact = snapshot(sleep: 420, steps: 8_000, activeMinutes: 30)

    #expect(engine.evaluate(below, at: now).vitalityAward == 0)
    #expect(engine.evaluate(exact, at: now).vitalityAward == 5)
    #expect(engine.evaluate(exact, at: now).trace.vitalityAward == 5)
  }

  @Test("Partial availability can use fresh known metrics")
  func partialAvailability() {
    let snapshot = HealthSnapshot(
      capturedAt: now,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .partial,
      steps: 8_000
    )

    let decision = engine.evaluate(snapshot, at: now)
    #expect(decision.theme == .activity)
    #expect(decision.vitalityAward == 2)
  }

  private func snapshot(sleep: Int?, steps: Int?, activeMinutes: Int?) -> HealthSnapshot {
    HealthSnapshot(
      capturedAt: now,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      sources: [HealthFixtures.appleWatch],
      sleepMinutes: sleep,
      steps: steps,
      activeMinutes: activeMinutes
    )
  }
}
