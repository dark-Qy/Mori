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
      #expect(run.ledger.events.count == 1)
      #expect(run.state.processedEventIDs.count == 1)
    }
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
