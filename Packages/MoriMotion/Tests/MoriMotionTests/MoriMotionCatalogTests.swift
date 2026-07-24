import Foundation
import Testing

@testable import MoriMotion

@Suite("Mori motion catalog")
struct MoriMotionCatalogTests {
  @Test("loads a validated catalog and keeps motion IDs open")
  func loadsCatalogAndOpenID() throws {
    let source = TestCatalog.make()
    let data = try JSONEncoder().encode(source)
    let loaded = try MoriMotionCatalog.load(data: data)

    #expect(loaded == source)
    #expect(MoriMotionID(rawValue: "future_social_motion").rawValue == "future_social_motion")
  }

  @Test("loads the repository product catalog contract")
  func loadsRepositoryCatalog() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let url = repositoryRoot
      .appendingPathComponent("Design")
      .appendingPathComponent("WatchCompanionAssets")
      .appendingPathComponent("characters")
      .appendingPathComponent("motion-catalog.json")
    let catalog = try MoriMotionCatalog.load(contentsOf: url)

    #expect(catalog.schemaVersion == 2)
    #expect(catalog.fallbackMotionID == .idleNeutral)
    #expect(catalog.motions.count == 16)
    #expect(try catalog.resolve("task_completed").motionID == "action_success")
  }

  @Test("resolves chained aliases and hatch rows without changing product frames")
  func aliasesAndAssetNames() throws {
    let catalog = TestCatalog.make(
      aliases: [
        TestCatalog.alias("celebrate", target: "task_completed"),
        TestCatalog.alias("task_completed", target: "action_success"),
        TestCatalog.hatchAlias("greeting", row: "waving"),
      ]
    )

    let resolved = try catalog.resolve("celebrate")
    #expect(resolved.motionID == "action_success")
    #expect(resolved.assetMotionID == "action_success")
    #expect(resolved.isAlias)
    #expect(
      try catalog.assetName(
        characterID: "polar_bear",
        motionID: "celebrate",
        frameIndex: 3
      ) == "character_polar_bear_action_success_03"
    )
    #expect(
      try catalog.assetName(
        characterID: "penguin",
        motionID: "greeting",
        frameIndex: 0
      ) == "character_penguin_waving_00"
    )
    #expect(try catalog.resolve("greeting").resolutionKind == .hatchV2Row)
  }

  @Test("detects alias cycles")
  func aliasCycle() {
    let catalog = TestCatalog.make(
      aliases: [
        TestCatalog.alias("first", target: "second"),
        TestCatalog.alias("second", target: "first"),
      ]
    )

    #expect(throws: MoriMotionCatalogError.self) {
      try catalog.resolve("first")
    }
  }

  @Test("formats and parses underscored character and motion asset names")
  func parsesAssetName() throws {
    let catalog = TestCatalog.make()
    let name = try catalog.assetName(
      characterID: "polar_bear",
      motionID: "story_reaction",
      frameIndex: 7
    )

    #expect(name == "character_polar_bear_story_reaction_07")
    #expect(
      catalog.parseAssetName(name)
        == MoriAssetReference(
          characterID: "polar_bear",
          assetMotionID: "story_reaction",
          frameIndex: 7
        )
    )
    #expect(catalog.parseAssetName("character_polar_bear_unknown_07") == nil)
    #expect(catalog.parseAssetName("character_penguin_story_reaction_99") == nil)
  }

  @Test("malformed catalogs deterministically load the emergency neutral catalog")
  func malformedCatalogFallback() {
    let result = MoriMotionCatalogLoader.loadOrFallback(
      data: Data(#"{"schemaVersion":999}"#.utf8)
    )

    #expect(result.usedFallback)
    #expect(result.errorDescription != nil)
    #expect(result.catalog.motions.map(\.id) == [.idleNeutral])
    #expect(result.catalog.characterIDs == ["penguin"])
  }
}
