import AppRuntime
import Foundation
import Testing

@Suite("Data source selection")
struct DataSourceSelectionTests {
  @Test("Build default keeps Mock in development and fails closed in production")
  func buildDefault() {
    #if DEBUG
      #expect(CompanionDataSource.defaultSelection == .mock1)
    #else
      #expect(CompanionDataSource.defaultSelection == .healthKit)
    #endif
  }

  @Test("Missing selection uses the build-appropriate safe default")
  func defaultSelection() async {
    let storage = makeRepository()
    defer { removeStorage(suiteName: storage.suiteName) }

    #expect(await storage.repository.load() == .defaultSelection)
  }

  #if DEBUG
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

    @Test("Peer selection preview and apply use the same idempotency rule")
    func peerSelectionPreview() async {
      let storage = makeRepository()
      defer { removeStorage(suiteName: storage.suiteName) }

      #expect(
        await storage.repository.wouldApplyPeerSelection(
          .mock2,
          token: "first"
        )
      )
      #expect(
        await storage.repository.applyPeerSelection(
          .mock2,
          token: "first"
        )
      )
      #expect(
        !(await storage.repository.wouldApplyPeerSelection(
          .mock2,
          token: "first"
        ))
      )
      #expect(
        !(await storage.repository.applyPeerSelection(
          .mock2,
          token: "first"
        ))
      )
      #expect(
        await storage.repository.wouldApplyPeerSelection(
          .mock2,
          token: "second"
        )
      )
      #expect(
        await storage.repository.applyPeerSelection(
          .mock2,
          token: "second"
        )
      )
    }

    @Test("A local save invalidates a prepared peer selection")
    func preparedPeerSelectionIsAtomic() async throws {
      let storage = makeRepository()
      defer { removeStorage(suiteName: storage.suiteName) }
      _ = await storage.repository.save(.mock1)
      let plan = try #require(
        await storage.repository.preparePeerSelection(
          .healthKit,
          token: "peer-health"
        )
      )
      #expect(plan.changesMode)

      _ = await storage.repository.save(.mock3)

      #expect(!(await storage.repository.commitPeerSelection(plan)))
      #expect(await storage.repository.load() == .mock3)
      #expect(
        await storage.repository.loadSelectionToken() != "peer-health"
      )
    }
  #endif

  @Test("Invalid stored selection uses the build-appropriate safe default")
  func invalidSelection() async {
    let storage = makeRepository(initialRawValue: "unknown")
    defer { removeStorage(suiteName: storage.suiteName) }

    #expect(await storage.repository.load() == .defaultSelection)
  }

  @Test("Unknown peer values cannot become a data-source selection")
  func rejectsUnknownRawValue() {
    #expect(CompanionDataSource(rawValue: "unknown") == nil)
  }

  @Test("All data sources expose stable product metadata")
  func casesAndMetadata() {
    #if DEBUG
      #expect(CompanionDataSource.allCases == [.healthKit, .mock1, .mock2, .mock3])
      #expect(
        CompanionDataSource.allCases.map(\.displayName) == [
          "Apple 健康", "Mock 1", "Mock 2", "Mock 3",
        ])
      #expect(
        CompanionDataSource.allCases.map(\.fixtureID) == [
          nil, "mock1", "mock2", "mock3",
        ])
      #expect(
        CompanionDataSource.allCases.map(\.isMock) == [
          false, true, true, true,
        ])
    #else
      #expect(CompanionDataSource.allCases == [.healthKit])
      #expect(CompanionDataSource.allCases.map(\.displayName) == ["Apple 健康"])
      #expect(CompanionDataSource.allCases.map(\.fixtureID) == [nil])
      #expect(CompanionDataSource.allCases.map(\.isMock) == [false])
    #endif
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
