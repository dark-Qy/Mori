import AppRuntime
import Foundation
import Testing

@Suite("Data source selection")
struct DataSourceSelectionTests {
  @Test("Missing selection defaults to Mock 1")
  func defaultSelection() async {
    let storage = makeRepository()
    defer { removeStorage(suiteName: storage.suiteName) }

    #expect(await storage.repository.load() == .mock1)
  }

  @Test("Selection round-trips as its raw string value")
  func roundTrip() async {
    let storage = makeRepository()
    defer { removeStorage(suiteName: storage.suiteName) }

    let firstToken = await storage.repository.save(.mock3)

    let verificationDefaults = UserDefaults(suiteName: storage.suiteName)
    #expect(verificationDefaults?.string(forKey: storage.key) == "mock3")
    #expect(await storage.repository.load() == .mock3)
    #expect(await storage.repository.loadSelectionToken() == firstToken)
  }

  @Test("Peer selection tokens distinguish same-Mock reselection from replay")
  func peerSelectionToken() async {
    let storage = makeRepository()
    defer { removeStorage(suiteName: storage.suiteName) }

    #expect(await storage.repository.applyPeerSelection(.mock2, token: "first"))
    #expect(!(await storage.repository.applyPeerSelection(.mock2, token: "first")))
    #expect(await storage.repository.applyPeerSelection(.mock2, token: "second"))
    #expect(await storage.repository.load() == .mock2)
    #expect(await storage.repository.loadSelectionToken() == "second")
  }

  @Test("Invalid stored selection falls back to Mock 1")
  func invalidSelection() async {
    let storage = makeRepository(initialRawValue: "unknown")
    defer { removeStorage(suiteName: storage.suiteName) }

    #expect(await storage.repository.load() == .mock1)
  }

  @Test("All data sources expose stable product metadata")
  func casesAndMetadata() {
    #expect(
      CompanionDataSource.allCases == [
        .healthKit, .mock1, .mock2, .mock3, .mock7Active, .mock7Recovery, .mock7Rhythm,
        .mock7Sparse, .mock7Stable,
      ])
    #expect(
      CompanionDataSource.allCases.map(\.displayName) == [
        "Apple 健康", "Mock 1", "Mock 2", "Mock 3", "35 日 · 活动旅程", "35 日 · 恢复旅程",
        "35 日 · 节律旅程", "35 日 · 片段旅程", "35 日 · 平稳旅程",
      ])
    #expect(
      CompanionDataSource.allCases.map(\.fixtureID) == [
        nil, "mock1", "mock2", "mock3", "mock7_active", "mock7_recovery", "mock7_rhythm",
        "mock7_sparse", "mock7_stable",
      ])
    #expect(
      CompanionDataSource.allCases.map(\.isMock) == [
        false, true, true, true, true, true, true, true, true,
      ])
    #expect(CompanionDataSource.isPeerExchangeFixtureID("mock2"))
    #expect(!CompanionDataSource.isPeerExchangeFixtureID(nil))
  }

  private func makeRepository(
    initialRawValue: String? = nil
  ) -> (repository: DataSourceSelectionRepository, suiteName: String, key: String) {
    let suiteName = "DataSourceSelectionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let key = "selection"
    if let initialRawValue {
      defaults.set(initialRawValue, forKey: key)
    }
    return (
      DataSourceSelectionRepository(defaults: defaults, key: key),
      suiteName,
      key
    )
  }

  private func removeStorage(suiteName: String) {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }
}
