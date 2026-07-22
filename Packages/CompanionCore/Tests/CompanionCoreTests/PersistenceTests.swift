import Domain
import Foundation
import Persistence
import Testing

@Suite("Versioned companion persistence")
struct PersistenceTests {
  private let codec = CompanionStateCodec()

  @Test("Current schema round-trips with deterministic JSON")
  func roundTrip() throws {
    let state = CompanionState(
      pet: PetState(name: "Pip", mood: .lively),
      growth: GrowthState(vitality: 13, bond: 2, insight: 1),
      story: StoryState(mainlineChapter: 2, memories: ["First sunrise"]),
      activeTheme: .activity,
      processedEventIDs: [uuid(1)]
    )

    let firstData = try codec.encode(state)
    let secondData = try codec.encode(state)
    let restored = try codec.decode(firstData)

    #expect(firstData == secondData)
    #expect(restored == state)
  }

  @Test("Set construction order cannot change persisted bytes")
  func canonicalCollections() throws {
    let first = CompanionState(
      story: StoryState(
        completedBeatIDs: ["main.day-2.first-step", "main.day-1.awakening"],
        unlockedSideStoryIDs: ["lost_ball", "rain_walk"]
      ),
      processedEventIDs: [uuid(2), uuid(1)]
    )
    let second = CompanionState(
      story: StoryState(
        completedBeatIDs: ["main.day-1.awakening", "main.day-2.first-step"],
        unlockedSideStoryIDs: ["rain_walk", "lost_ball"]
      ),
      processedEventIDs: [uuid(1), uuid(2)]
    )

    #expect(try codec.encode(first) == codec.encode(second))
  }

  @Test("Future schemas fail closed")
  func futureSchema() throws {
    let data = try JSONEncoder().encode(
      PersistedCompanionState(schemaVersion: 99, state: CompanionState()))

    #expect(throws: PersistenceError.unsupportedFutureSchema(99)) {
      try codec.decode(data)
    }
  }

  @Test("Nested state schemas fail closed")
  func nestedStateSchema() throws {
    let futureState = CompanionState(schemaVersion: 99)
    let data = try codec.encode(futureState)

    #expect(throws: PersistenceError.unsupportedStateSchema(99)) {
      try codec.decode(data)
    }
  }

  @Test("Legacy schemas require an explicit migration")
  func migrationStub() throws {
    let legacy = try JSONEncoder().encode(
      PersistedCompanionState(schemaVersion: 0, state: CompanionState()))

    #expect(throws: PersistenceError.migrationUnavailable(from: 0, to: 1)) {
      try codec.decode(legacy)
    }

    let expected = CompanionState(growth: GrowthState(vitality: 7))
    let restored = try codec.decode(
      legacy, migrator: FixtureMigration(output: try codec.encode(expected)))
    #expect(restored == expected)
  }

  @Test("Malformed envelopes are rejected before decoding state")
  func malformedEnvelope() {
    let data = Data("{\"state\":{}}".utf8)
    #expect(throws: PersistenceError.malformedEnvelope) {
      try codec.decode(data)
    }
  }

  private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
  }
}

private struct FixtureMigration: CompanionStateMigrating {
  var output: Data

  func migrate(_ data: Data, from sourceVersion: Int, to targetVersion: Int) throws -> Data {
    #expect(sourceVersion == 0)
    #expect(targetVersion == 1)
    return output
  }
}
