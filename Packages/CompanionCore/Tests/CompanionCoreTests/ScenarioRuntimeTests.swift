import DebugScenarioSupport
import Domain
import Foundation
import MockKit
import Testing

@Suite("Executable mock scenarios")
struct ScenarioRuntimeTests {
  @Test("Every repository fixture creates an executable runtime")
  func everyFixtureRuns() throws {
    for url in try fixtureURLs() {
      let fixture = try ScenarioFixture(contentsOf: url)
      let runtime = try MockScenarioRuntime(fixture: fixture)
      let run = try MockScenarioRun(runtime: runtime)

      #expect(runtime.id == url.deletingPathExtension().lastPathComponent)
      #expect(runtime.mockBadgeVisible)
      let expectedEventCount = runtime.hasCompletedOnboarding ? runtime.healthSnapshots.count : 0
      #expect(run.ledger.events.count == expectedEventCount)
      #expect(run.state.processedEventIDs.count == expectedEventCount)
    }
  }

  @Test("Thirty-five-day demos use real daily history and self-check their latest trends")
  func sevenDayScenarios() throws {
    let expectedStatuses: [String: [TrendMetric: PersonalTrendStatus]] = [
      "mock7_stable": [
        .sleepDuration: .withinPersonalRange,
        .steps: .withinPersonalRange,
        .activeMinutes: .withinPersonalRange,
        .sleepTiming: .withinPersonalRange,
      ],
      "mock7_recovery": [
        .sleepDuration: .belowPersonalRange,
        .steps: .withinPersonalRange,
        .activeMinutes: .withinPersonalRange,
        .sleepTiming: .withinPersonalRange,
      ],
      "mock7_active": [
        .sleepDuration: .withinPersonalRange,
        .steps: .abovePersonalRange,
        .activeMinutes: .abovePersonalRange,
        .sleepTiming: .withinPersonalRange,
      ],
      "mock7_sparse": [
        .sleepDuration: .withinPersonalRange,
        .steps: .withinPersonalRange,
        .activeMinutes: .withinPersonalRange,
        .sleepTiming: .withinPersonalRange,
      ],
      "mock7_rhythm": [
        .sleepDuration: .withinPersonalRange,
        .steps: .withinPersonalRange,
        .activeMinutes: .withinPersonalRange,
        .sleepTiming: .abovePersonalRange,
      ],
    ]

    for (name, statuses) in expectedStatuses {
      let runtime = try runtime(named: name)
      let run = try MockScenarioRun(runtime: runtime)
      let trend = try #require(runtime.personalHealthTrend)

      #expect(runtime.healthSnapshots.count == 35)
      #expect(Set(runtime.healthSnapshots.map(\.localDay)).count == 35)
      #expect(run.ledger.events.count == 35)
      #expect(Set(run.ledger.events.map(\.eventID)).count == 35)
      #expect(run.state.processedEventIDs.count == 35)
      #expect(trend.recentDays.count == 7)
      for (metric, expectedStatus) in statuses {
        #expect(
          trend.observations.first(where: { $0.metric == metric })?.status == expectedStatus,
          "\(name) \(metric.rawValue)"
        )
      }
    }

    let recovery = try runtime(named: "mock7_recovery")
    let recoveryRun = try MockScenarioRun(runtime: recovery)
    #expect(recovery.healthSnapshot.sleepMinutes == 320)
    #expect(recoveryRun.state.activeTheme == .recovery)

    let active = try runtime(named: "mock7_active")
    let activeRun = try MockScenarioRun(runtime: active)
    #expect(active.healthSnapshot.steps == 10_800)
    #expect(active.healthSnapshot.workouts.first?.durationMinutes == 45)
    let activeWorkouts = active.healthSnapshots.flatMap(\.workouts)
    #expect(
      activeWorkouts.map(\.activity)
        == [.walking, .swimming, .badminton, .tennis, .soccer]
    )
    #expect(activeWorkouts.map(\.durationMinutes) == [20, 25, 30, 40, 45])
    let iso8601 = ISO8601DateFormatter()
    let expectedWorkoutStarts = [
      "2026-06-22T18:10:00+08:00",
      "2026-06-29T19:00:00+08:00",
      "2026-07-06T18:30:00+08:00",
      "2026-07-13T17:50:00+08:00",
      "2026-07-23T17:30:00+08:00",
    ].compactMap(iso8601.date(from:))
    #expect(expectedWorkoutStarts.count == 5)
    #expect(
      activeWorkouts.map(\.startedAt)
        == expectedWorkoutStarts
    )
    #expect(active.eligibleRandomStoryID == "lost_ball")
    #expect(!activeRun.state.story.unlockedSideStoryIDs.contains("lost_ball"))

    let sparseRuntime = try runtime(named: "mock7_sparse")
    let sparse = try #require(sparseRuntime.personalHealthTrend)
    #expect(sparse.usableBaselineDayCount == 20)
    #expect(sparse.recentDays.filter { $0.steps == nil }.count == 2)
  }

  @Test("Fresh install derives onboarding from installation state and keeps an empty ledger")
  func freshInstallIsStateDerived() throws {
    let runtime = try runtime(named: "fresh_install")
    let run = try MockScenarioRun(runtime: runtime)

    #expect(!runtime.hasCompletedOnboarding)
    #expect(runtime.primaryState == .onboarding)
    #expect(run.ledger.events.isEmpty)
    #expect(run.state == runtime.initialState)
  }

  @Test("Health scenario projects samples into a rule-authoritative state")
  func healthScenarioProjection() throws {
    let runtime = try runtime(named: "health_normal")
    let run = try MockScenarioRun(runtime: runtime)

    #expect(runtime.healthSnapshot.sleepMinutes == 450)
    #expect(runtime.healthSnapshot.steps == 3_250)
    #expect(runtime.healthSnapshot.restingHeartRateBPM == 58)
    #expect(run.state.growth.vitality == 2)
    #expect(run.state.activeTheme == .activity)
    #expect(run.state.lastDecisionTrace?.ruleSetVersion == 1)
  }

  @Test("Stale health is neutral and never grants vitality")
  func staleHealthIsNeutral() throws {
    let run = try MockScenarioRun(runtime: runtime(named: "sleep_stale"))

    #expect(run.state.activeTheme == .neutral)
    #expect(run.state.growth.vitality == 0)
    #expect(run.state.pet.mood == .neutral)
  }

  @Test("Soccer workout is represented as eligibility, not a guaranteed story")
  func soccerIsOnlyEligible() throws {
    let runtime = try runtime(named: "soccer_workout")
    let run = try MockScenarioRun(runtime: runtime)

    #expect(runtime.healthSnapshot.workouts.first?.activity == .soccer)
    #expect(runtime.eligibleRandomStoryID == "lost_ball")
    #expect(!run.state.story.unlockedSideStoryIDs.contains("lost_ball"))
  }

  @Test("Three product demos remain distinct and exercise the agreed branches")
  func productDemoFixtures() throws {
    let normal = try runtime(named: "mock1")
    let care = try runtime(named: "mock2")
    let careRun = try MockScenarioRun(runtime: care)
    let active = try runtime(named: "mock3")

    #expect(normal.healthSnapshot.sleepMinutes == 450)
    #expect(normal.healthSnapshot.steps == 3_250)

    #expect(care.healthSnapshot.stateOfMindSamples?.first?.labels.contains(.stressed) == true)
    #expect(careRun.state.lastStateOfMind?.labels.contains(.stressed) == true)
    #expect(
      care.initialState.pet.relationshipPresence(
        at: care.clock.now,
        timeZone: TimeZone(identifier: care.clock.timeZoneIdentifier)!
      ) == .quietlyMissingYou
    )

    #expect(active.healthSnapshot.steps == 18_420)
    #expect(active.healthSnapshot.workouts.first?.activity == .soccer)
    #expect(active.eligibleRandomStoryID == "lost_ball")
  }

  @Test("Time travel and replay remain deterministic")
  func timeTravelReplay() throws {
    var run = try MockScenarioRun(runtime: runtime(named: "health_normal"))
    let anchor = run.clock.now
    let first = try run.interact(kind: "pat")
    run.advance(by: 3_600)
    let second = try run.interact(kind: "check-in")
    let stateBeforeReplay = run.state

    #expect(first.eventID != second.eventID)
    #expect(run.clock.now == anchor.addingTimeInterval(3_600))
    #expect(run.state.pet.lastInteractionAt == run.clock.now)

    try run.replay()
    #expect(run.state == stateBeforeReplay)
  }

  @Test("Launch arguments support both repository and inline forms")
  func launchArgumentParsing() {
    #expect(
      MockLaunchArguments.selection(from: ["App", "-MockScenario", "health_partial"])
        == .scenario("health_partial")
    )
    #expect(
      MockLaunchArguments.selection(from: ["App", "--mock-scenario=activity_high"])
        == .scenario("activity_high")
    )
    #expect(MockLaunchArguments.selection(from: ["App", "-MockScenario"]) == .none)
  }

  @Test("Repository catalog exactly matches checked-in scenario fixtures")
  func repositoryCatalogMatchesFixtures() throws {
    let stems = Set(
      try fixtureURLs().map { $0.deletingPathExtension().lastPathComponent }
    )

    #expect(stems == DebugScenarioCatalog.allowlistedIDs)

    let fileListURL = repositoryRoot()
      .appendingPathComponent("Apps/Apple/Configuration/DebugScenarioFixtures.xcfilelist")
    let listedStems = try Set(
      String(contentsOf: fileListURL, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map { line in
          URL(fileURLWithPath: String(line))
            .deletingPathExtension()
            .lastPathComponent
        }
    )
    #expect(listedStems == DebugScenarioCatalog.allowlistedIDs)
  }

  @Test("Repository selection is disabled before reading fixture data")
  func repositorySelectionCanBeDisabled() {
    var requestedData = false
    let selection = DebugScenarioCatalog.selection(
      from: ["App", "--mock-scenario=health_normal"],
      enabled: false
    ) { _ in
      requestedData = true
      return nil
    }

    guard case .none = selection else {
      Issue.record("Disabled catalog must ignore mock launch arguments")
      return
    }
    #expect(requestedData == false)
  }

  @Test("Repository selection rejects unknown IDs without resolving a path")
  func repositorySelectionRejectsUnknownID() {
    var requestedData = false
    let selection = DebugScenarioCatalog.selection(
      from: ["App", "--mock-scenario=../../private"],
      enabled: true
    ) { _ in
      requestedData = true
      return nil
    }

    guard case .invalid(let requestedID) = selection else {
      Issue.record("Unknown identifiers must fail closed")
      return
    }
    #expect(requestedID == "../../private")
    #expect(requestedData == false)
  }

  @Test("Repository selection creates an executable runtime from canonical bytes")
  func repositorySelectionCreatesRuntime() throws {
    let selection = DebugScenarioCatalog.selection(
      from: ["App", "-MockScenario", "soccer_workout"],
      enabled: true
    ) { identifier in
      try? Data(
        contentsOf: repositoryRoot()
          .appendingPathComponent("Fixtures/Scenarios/\(identifier).json")
      )
    }

    guard case .scenario(let runtime) = selection else {
      Issue.record("Allowlisted canonical fixture should resolve")
      return
    }
    #expect(runtime.id == "soccer_workout")
    #expect(runtime.healthSnapshot.workouts.first?.activity == .soccer)
    #expect(runtime.eligibleRandomStoryID == "lost_ball")
    #expect(!runtime.companionState.story.unlockedSideStoryIDs.contains("lost_ball"))
  }

  private func runtime(named name: String) throws -> MockScenarioRuntime {
    let url = repositoryRoot()
      .appendingPathComponent("Fixtures/Scenarios/\(name).json")
    return try MockScenarioRuntime(fixture: ScenarioFixture(contentsOf: url))
  }

  private func fixtureURLs() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: repositoryRoot().appendingPathComponent("Fixtures/Scenarios", isDirectory: true),
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
      url.deleteLastPathComponent()
    }
    return url
  }
}
