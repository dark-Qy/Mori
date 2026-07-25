import Foundation
import MockKit
import Testing

@Suite("Repository mock fixture contract")
struct FixtureContractTests {
  @Test("Every required scenario decodes and remains visibly mocked")
  func fixturesDecode() throws {
    let required = Set([
      "activity_high", "ai_malformed", "ai_offline", "fresh_install", "health_no_data",
      "health_normal", "health_partial", "notification_denied", "outfit_locked",
      "mock1", "mock2", "mock3", "mock4", "mock5", "mock6", "outfit_unlocked",
      "permission_not_requested", "pet_new",
      "mock7_active", "mock7_recovery", "mock7_rhythm", "mock7_sparse", "mock7_stable",
      "sleep_stale",
      "soccer_workout", "sync_unreachable",
    ])
    let fixtureDirectory = repositoryRoot()
      .appendingPathComponent("Fixtures/Scenarios", isDirectory: true)
    let fixtureURLs = try FileManager.default.contentsOfDirectory(
      at: fixtureDirectory,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }

    #expect(Set(fixtureURLs.map { $0.deletingPathExtension().lastPathComponent }) == required)
    for url in fixtureURLs {
      let fixture = try ScenarioFixture(data: Data(contentsOf: url))
      let issues = fixture.validationIssues(
        fileStem: url.deletingPathExtension().lastPathComponent
      )
      #expect(issues.isEmpty, "\(url.lastPathComponent): \(issues.joined(separator: ", "))")
    }
  }

  private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
      url.deleteLastPathComponent()
    }
    return url
  }
}
