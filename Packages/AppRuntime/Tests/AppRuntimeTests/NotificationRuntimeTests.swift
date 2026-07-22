import AppRuntime
import AppleAdapters
import Domain
import Foundation
import Testing

@Suite("Proactive interaction runtime")
struct NotificationRuntimeTests {
  private let now = Date(timeIntervalSince1970: 1_760_000_000)

  @Test("No rule decision means silence")
  func silenceWithoutContext() {
    #expect(ProactiveInteractionPlanner().plan(for: CompanionState(), now: now) == nil)
  }

  @Test("Recovery plan uses approved copy and adapter policy can suppress it")
  func recoveryPlanAndPolicy() async throws {
    var state = CompanionState(activeTheme: .recovery)
    state.lastDecisionTrace = DecisionTrace(
      ruleSetVersion: 1,
      evaluatedAt: now,
      selectedTheme: .recovery,
      vitalityAward: 0,
      steps: []
    )
    let plan = try #require(ProactiveInteractionPlanner().plan(for: state, now: now, delay: 60))
    let client = MockLocalNotificationClient(state: .authorized, calendar: utcCalendar)
    let service = ProactiveInteractionService(client: client)

    let decision = try await service.schedule(
      plan,
      policy: NotificationPolicy(quietHours: QuietHours(startMinute: 0, endMinute: 1_439))
    )

    #expect(decision == .suppressQuietHours)
    #expect(await client.pending.isEmpty)
  }

  @Test("Approved plan creates a deep-linked local notification")
  func schedulesApprovedPlan() async throws {
    var state = CompanionState(activeTheme: .activity)
    state.lastDecisionTrace = DecisionTrace(
      ruleSetVersion: 1,
      evaluatedAt: now,
      selectedTheme: .activity,
      vitalityAward: 3,
      steps: []
    )
    let plan = try #require(ProactiveInteractionPlanner().plan(for: state, now: now, delay: 60))
    let client = MockLocalNotificationClient(state: .authorized, calendar: utcCalendar)

    #expect(
      try await ProactiveInteractionService(client: client).schedule(
        plan,
        policy: NotificationPolicy(minimumCooldown: 4 * 3_600)
      ) == .allow
    )
    #expect(await client.pending[plan.id]?.deepLink?.route == "pet/activity")
  }

  @Test("Low activity copy does not claim a workout occurred")
  func lowActivityCopy() throws {
    var state = CompanionState(activeTheme: .activity)
    state.lastDecisionTrace = DecisionTrace(
      ruleSetVersion: 1,
      evaluatedAt: now,
      selectedTheme: .activity,
      vitalityAward: 0,
      steps: [
        RuleTraceStep(
          ruleID: "phase1.theme.activity.low-activity",
          outcome: .matched,
          explanation: "test"
        )
      ]
    )

    let plan = try #require(ProactiveInteractionPlanner().plan(for: state, now: now))
    #expect(plan.body.contains("走两分钟"))
    #expect(!plan.body.contains("已经记下"))
  }

  @Test("Initiative timing is seeded, bounded, and replayable")
  func seededInitiativeTiming() throws {
    var delays = Set<TimeInterval>()

    for index in 1...32 {
      var state = CompanionState(
        activeTheme: .recovery,
        processedEventIDs: [uuid(index)]
      )
      state.lastDecisionTrace = DecisionTrace(
        ruleSetVersion: 1,
        evaluatedAt: now,
        selectedTheme: .recovery,
        vitalityAward: 0,
        steps: []
      )

      let first = try #require(ProactiveInteractionPlanner().plan(for: state, now: now))
      let replay = try #require(ProactiveInteractionPlanner().plan(for: state, now: now))
      let delay = first.fireDate.timeIntervalSince(now)

      #expect(first == replay)
      #expect(delay >= ProactiveInteractionPlanner.minimumSeededDelay)
      #expect(delay <= ProactiveInteractionPlanner.maximumSeededDelay)
      #expect(delay.truncatingRemainder(dividingBy: 60) == 0)
      delays.insert(delay)
    }

    #expect(delays.count > 1)
  }

  @Test("An explicit delay remains available for deterministic adapters and tests")
  func explicitDelay() throws {
    var state = CompanionState(activeTheme: .recovery)
    state.lastDecisionTrace = DecisionTrace(
      ruleSetVersion: 1,
      evaluatedAt: now,
      selectedTheme: .recovery,
      vitalityAward: 0,
      steps: []
    )

    let plan = try #require(
      ProactiveInteractionPlanner().plan(for: state, now: now, delay: 75)
    )
    #expect(plan.fireDate == now.addingTimeInterval(75))
  }

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
  }
}
