import Domain
import Foundation
import Persistence
import Testing

@Suite("Hidden personalization memory and Mori personality")
struct PersonalizationTests {
  private let start = Date(timeIntervalSince1970: 1_760_000_000)

  @Test("Only typed safe evidence is recorded and Mori adapts gradually")
  func recordsAllowedEvidenceAndAdaptsGradually() async throws {
    let repository = PersonalizationRepository(storage: InMemoryPersonalizationStorage())

    try await repository.record(
      .verifiedWorkout(activity: .tennis, durationMinutes: 60, evidenceID: "workout-1"),
      at: start
    )
    var state = try await repository.state(at: start)

    #expect(state.memories.count == 1)
    #expect(state.memories[0].evidence[0].source == .verifiedWorkout)
    #expect(state.owner.activityAffinities[.tennis, default: 0] > 0)
    #expect(abs(state.mori.activityAffinities[.tennis, default: 0] - 0.08) < 0.000_001)
    #expect(state.compactProjection.preferredActivities == [])

    try await repository.record(
      .verifiedWorkout(activity: .tennis, durationMinutes: 45, evidenceID: "workout-2"),
      at: start.addingTimeInterval(86_400)
    )
    state = try await repository.state(at: start.addingTimeInterval(86_400))

    #expect(state.memories.count == 1)
    #expect(state.memories[0].reinforcementCount == 2)
    #expect(state.memories[0].evidence.count == 2)
    #expect(abs(state.mori.activityAffinities[.tennis, default: 0] - 0.16) < 0.000_001)
    #expect(state.compactProjection.preferredActivities == [.tennis])
    #expect(state.mori.core == .warmCuriousNonJudgmental)
  }

  @Test("Explicit preferences replace stale preference and preserve the stable core")
  func explicitPreferenceOverrides() async throws {
    let repository = PersonalizationRepository(storage: InMemoryPersonalizationStorage())

    try await repository.record(
      .explicitExpressionPreference(style: .playful, evidenceID: "choice-1"),
      at: start
    )
    try await repository.record(
      .interactionRhythm(rhythm: .lively, sampleCount: 5, evidenceID: "rhythm-1"),
      at: start
    )

    let projection = try await repository.projection(at: start)
    #expect(projection.core == .warmCuriousNonJudgmental)
    #expect(projection.expressionStyle == .playful)
    #expect(projection.companionshipRhythm == .lively)
    #expect(abs(projection.playfulness - 0.66) < 0.000_001)
    #expect(abs(projection.energy - 0.58) < 0.000_001)
  }

  @Test("The latest explicit expression choice replaces the earlier choice")
  func latestExplicitExpressionWins() async throws {
    let repository = PersonalizationRepository(storage: InMemoryPersonalizationStorage())
    try await repository.record(
      .explicitExpressionPreference(style: .playful, evidenceID: "choice-1"),
      at: start
    )
    try await repository.record(
      .explicitExpressionPreference(style: .concise, evidenceID: "choice-2"),
      at: start.addingTimeInterval(1)
    )

    let state = try await repository.state(at: start.addingTimeInterval(1))
    #expect(state.owner.preferredExpression == .concise)
    #expect(state.compactProjection.expressionStyle == .concise)
    #expect(
      state.memories.filter {
        if case .expression = $0.subject { return true }
        return false
      }.count == 1
    )
  }

  @Test("Sleep routine requires a multi-day aggregate and never changes Mori core")
  func sleepRoutineMinimumSampleBoundary() async throws {
    let repository = PersonalizationRepository(storage: InMemoryPersonalizationStorage())

    try await repository.record(
      .sleepRoutine(
        band: .from2200To2359,
        regularity: .steady,
        sampleCount: PersonalizationSignal.minimumSleepRoutineSampleCount - 1,
        evidenceID: "routine-too-small"
      ),
      at: start
    )
    var state = try await repository.state(at: start)
    #expect(state.memories.isEmpty)
    #expect(state.compactProjection.sleepRoutine == nil)

    try await repository.record(
      .sleepRoutine(
        band: .from2200To2359,
        regularity: .steady,
        sampleCount: PersonalizationSignal.minimumSleepRoutineSampleCount,
        evidenceID: "routine-week-1"
      ),
      at: start
    )
    state = try await repository.state(at: start)

    #expect(state.memories.count == 1)
    #expect(
      state.memories[0].subject
        == .sleepRoutine(band: .from2200To2359, regularity: .steady)
    )
    #expect(state.memories[0].evidence[0].source == .aggregateRoutine)
    #expect(state.compactProjection.sleepRoutine?.band == .from2200To2359)
    #expect(state.compactProjection.sleepRoutine?.regularity == .steady)
    #expect(state.mori == .original)
    #expect(state.mori.core == .warmCuriousNonJudgmental)
  }

  @Test("Repeated sleep aggregates reinforce only the coarse routine projection")
  func repeatedSleepRoutineReinforcesProjection() async throws {
    let repository = PersonalizationRepository(storage: InMemoryPersonalizationStorage())
    let firstSignal = PersonalizationSignal.sleepRoutine(
      band: .afterMidnight,
      regularity: .varied,
      sampleCount: 7,
      evidenceID: "routine-week-1"
    )
    try await repository.record(firstSignal, at: start)
    let first = try await repository.state(at: start)

    try await repository.record(
      .sleepRoutine(
        band: .afterMidnight,
        regularity: .varied,
        sampleCount: 7,
        evidenceID: "routine-week-2"
      ),
      at: start.addingTimeInterval(7 * 86_400)
    )
    let second = try await repository.state(at: start.addingTimeInterval(7 * 86_400))

    #expect(second.memories.count == 1)
    #expect(second.memories[0].reinforcementCount == 2)
    #expect(second.memories[0].weight > first.memories[0].weight)
    #expect(
      second.compactProjection.sleepRoutine?.confidence
        == second.memories[0].weight
    )
    #expect(second.mori == .original)
  }

  @Test("Sleep routine persistence contains no individual sleep or health fields")
  func sleepRoutineStoresNoSensitiveSamples() throws {
    let state = PersonalizationEngine().recording(
      .sleepRoutine(
        band: .before2200,
        regularity: .steady,
        sampleCount: 8,
        evidenceID: "routine-summary"
      ),
      in: PersonalizationState(),
      at: start
    )
    let data = try PersonalizationStateCodec().encode(state)
    let serialized = try #require(String(data: data, encoding: .utf8))

    #expect(serialized.contains("before2200"))
    #expect(serialized.contains("steady"))
    #expect(!serialized.contains("sampleCount"))
    #expect(!serialized.localizedCaseInsensitiveContains("duration"))
    #expect(!serialized.localizedCaseInsensitiveContains("sleepStage"))
    #expect(!serialized.localizedCaseInsensitiveContains("heart"))
    #expect(!serialized.localizedCaseInsensitiveContains("bedtimeMinutes"))
  }

  @Test("Disabled and cleared sleep routines fail closed")
  func disabledAndClearedSleepRoutine() async throws {
    let repository = PersonalizationRepository(storage: InMemoryPersonalizationStorage())
    try await repository.record(
      .sleepRoutine(
        band: .before2200,
        regularity: .steady,
        sampleCount: 7,
        evidenceID: "routine-week-1"
      ),
      at: start
    )
    try await repository.setEnabled(false)
    try await repository.record(
      .sleepRoutine(
        band: .afterMidnight,
        regularity: .varied,
        sampleCount: 14,
        evidenceID: "routine-disabled"
      ),
      at: start
    )

    var state = try await repository.state(at: start)
    #expect(state.memories.count == 1)
    #expect(state.compactProjection.sleepRoutine == nil)
    #expect(state.compactProjection.isPersonalized == false)

    try await repository.clearLearnedData()
    state = try await repository.state(at: start)
    #expect(state.isEnabled == false)
    #expect(state.memories.isEmpty)
    #expect(state.owner.sleepRoutine == nil)
    #expect(state.mori == .original)
  }

  @Test("Sleep routine expires instead of becoming a permanent profile")
  func sleepRoutineExpires() async throws {
    let repository = PersonalizationRepository(storage: InMemoryPersonalizationStorage())
    try await repository.record(
      .sleepRoutine(
        band: .from2200To2359,
        regularity: .steady,
        sampleCount: 7,
        evidenceID: "routine-week-1"
      ),
      at: start
    )

    let expired = try await repository.state(
      at: start.addingTimeInterval(61 * 86_400)
    )
    #expect(expired.memories.isEmpty)
    #expect(expired.owner.sleepRoutine == nil)
    #expect(expired.compactProjection.sleepRoutine == nil)
  }

  @Test("Disabling personalization keeps data but stops reads and writes from using it")
  func disableFailsClosed() async throws {
    let repository = PersonalizationRepository(storage: InMemoryPersonalizationStorage())
    try await repository.record(
      .explicitInterest(interest: .outdoors, affinity: 1, evidenceID: "choice-1"),
      at: start
    )
    let learned = try await repository.state(at: start)
    try await repository.setEnabled(false)

    try await repository.record(
      .verifiedWorkout(activity: .swimming, durationMinutes: 90, evidenceID: "workout-1"),
      at: start
    )
    let disabled = try await repository.state(at: start)
    let projection = try await repository.projection(at: start)

    #expect(disabled.memories == learned.memories)
    #expect(disabled.owner == learned.owner)
    #expect(disabled.isEnabled == false)
    #expect(projection.isPersonalized == false)
    #expect(projection.preferredActivities.isEmpty)
    #expect(projection.interests.isEmpty)
    #expect(projection.expressionStyle == .gentle)
  }

  @Test("Clear erases evidence and adaptive traits while preserving the toggle")
  func clearLearnedData() async throws {
    let storage = InMemoryPersonalizationStorage()
    let repository = PersonalizationRepository(storage: storage)
    try await repository.record(
      .verifiedWorkout(activity: .badminton, durationMinutes: 75, evidenceID: "workout-1"),
      at: start
    )
    try await repository.setEnabled(false)

    try await repository.clearLearnedData()
    let cleared = try await repository.state(at: start)
    let reopened = PersonalizationRepository(storage: storage)
    let reloaded = try await reopened.state(at: start)

    #expect(cleared == PersonalizationState(isEnabled: false))
    #expect(reloaded == cleared)
  }

  @Test("Weak memories decay and expired memories are removed")
  func decayAndExpiry() async throws {
    let repository = PersonalizationRepository(storage: InMemoryPersonalizationStorage())
    try await repository.record(
      .interactionRhythm(rhythm: .quiet, sampleCount: 5, evidenceID: "interaction-1"),
      at: start
    )

    let afterThirtyDays = try await repository.state(
      at: start.addingTimeInterval(30 * 86_400)
    )
    #expect(afterThirtyDays.memories.count == 1)
    #expect(afterThirtyDays.memories[0].weight < 0.35)

    let afterExpiry = try await repository.state(
      at: start.addingTimeInterval(91 * 86_400)
    )
    #expect(afterExpiry.memories.isEmpty)
    #expect(afterExpiry.owner.companionshipRhythm == .balanced)
    #expect(afterExpiry.mori == .original)
  }

  @Test("Expired adaptive traits converge with time but not repeated reads")
  func expiredTraitsConvergeWithTime() {
    let engine = PersonalizationEngine()
    let residual = PersonalizationState(
      mori: MoriPersonalityProfile(
        energy: 0.58,
        playfulness: 0.66,
        brevity: 0.45,
        activityAffinities: [.tennis: 0.16]
      ),
      lastMoriAdaptedAt: start
    )

    let sameInstant = engine.maintaining(residual, at: start)
    let afterOneDay = engine.maintaining(
      sameInstant,
      at: start.addingTimeInterval(86_400)
    )
    let repeatedRead = engine.maintaining(
      afterOneDay,
      at: start.addingTimeInterval(86_400)
    )
    let afterTwoDays = engine.maintaining(
      repeatedRead,
      at: start.addingTimeInterval(2 * 86_400)
    )

    #expect(sameInstant == residual)
    #expect(abs(afterOneDay.mori.energy - 0.5) < 0.000_001)
    #expect(abs(afterOneDay.mori.playfulness - 0.58) < 0.000_001)
    #expect(abs(afterOneDay.mori.activityAffinities[.tennis, default: 0] - 0.08) < 0.000_001)
    #expect(repeatedRead == afterOneDay)
    #expect(afterTwoDays.mori == .original)
    #expect(afterTwoDays.mori.activityAffinities.isEmpty)
  }

  @Test("Versioned state round-trips deterministically")
  func versionedRoundTrip() throws {
    let codec = PersonalizationStateCodec()
    let engine = PersonalizationEngine()
    let state = engine.recording(
      .explicitActivityPreference(activity: .soccer, affinity: 0.8, evidenceID: "choice-1"),
      in: PersonalizationState(),
      at: start
    )

    let first = try codec.encode(state)
    let second = try codec.encode(state)
    let decoded = try codec.decode(first)

    #expect(first == second)
    #expect(decoded == state)
  }

  @Test("Profile dictionary construction order cannot change persisted bytes")
  func canonicalProfileCollections() throws {
    let codec = PersonalizationStateCodec()
    let first = PersonalizationState(
      owner: OwnerAffinityProfile(
        activityAffinities: [.soccer: 0.8, .tennis: 0.6],
        interestAffinities: [.teamSports: 0.8, .racketSports: 0.6]
      ),
      mori: MoriPersonalityProfile(
        activityAffinities: [.soccer: 0.16, .tennis: 0.08],
        interestAffinities: [.teamSports: 0.16, .racketSports: 0.08]
      )
    )
    let second = PersonalizationState(
      owner: OwnerAffinityProfile(
        activityAffinities: [.tennis: 0.6, .soccer: 0.8],
        interestAffinities: [.racketSports: 0.6, .teamSports: 0.8]
      ),
      mori: MoriPersonalityProfile(
        activityAffinities: [.tennis: 0.08, .soccer: 0.16],
        interestAffinities: [.racketSports: 0.08, .teamSports: 0.16]
      )
    )

    #expect(first == second)
    #expect(try codec.encode(first) == codec.encode(second))
  }

  @Test("Malformed and future schemas fail closed")
  func persistenceFailures() throws {
    let codec = PersonalizationStateCodec()
    #expect(throws: PersonalizationPersistenceError.malformedEnvelope) {
      try codec.decode(Data("not-json".utf8))
    }

    let futureEnvelope = PersistedPersonalizationState(schemaVersion: 99, state: .init())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    #expect(throws: PersonalizationPersistenceError.unsupportedFutureSchema(99)) {
      try codec.decode(encoder.encode(futureEnvelope))
    }

    let futureState = PersonalizationState(schemaVersion: 99)
    #expect(throws: PersonalizationPersistenceError.unsupportedStateSchema(99)) {
      try codec.decode(codec.encode(futureState))
    }
  }

  @Test("Legacy incomplete envelopes reach the migrator through the schema header")
  func legacyEnvelopeMigration() throws {
    let codec = PersonalizationStateCodec()
    let legacy = Data(
      """
      {"schemaVersion":0,"state":{"enabled":true,"legacyMemories":[]}}
      """.utf8
    )
    #expect(
      throws: PersonalizationPersistenceError.migrationUnavailable(from: 0, to: 1)
    ) {
      try codec.decode(legacy)
    }

    let expected = PersonalizationState(
      owner: OwnerAffinityProfile(interestAffinities: [.exploration: 0.7])
    )
    let migrated = try codec.decode(
      legacy,
      migrator: PersonalizationFixtureMigration(output: try codec.encode(expected))
    )

    #expect(migrated == expected)
  }

  @Test("File storage is private, excluded from backup, and reloadable")
  func fileRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mori-personalization-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("personalization.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = PersonalizationRepository(
      storage: FilePersonalizationStorage(fileURL: fileURL)
    )
    try await first.record(
      .verifiedWorkout(activity: .swimming, durationMinutes: 30, evidenceID: "workout-1"),
      at: start
    )
    let second = PersonalizationRepository(
      storage: FilePersonalizationStorage(fileURL: fileURL)
    )

    #expect(try await second.state(at: start) == first.state(at: start))
    #expect(
      try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    )
  }

  @Test("Evidence is bounded and deterministic for mock replays")
  func boundedDeterministicEvidence() async throws {
    func replay() async throws -> PersonalizationState {
      let repository = PersonalizationRepository(storage: InMemoryPersonalizationStorage())
      for day in 0..<20 {
        try await repository.record(
          .verifiedWorkout(
            activity: .walking,
            durationMinutes: 30,
            evidenceID: "workout-\(day)"
          ),
          at: start.addingTimeInterval(Double(day) * 86_400)
        )
      }
      return try await repository.state(at: start.addingTimeInterval(19 * 86_400))
    }

    let first = try await replay()
    let second = try await replay()
    #expect(first == second)
    #expect(first.memories[0].evidence.count == PersonalizationMemory.maximumEvidenceCount)
    #expect(first.memories[0].evidence.first?.id == "workout-8")
    #expect(first.memories[0].evidence.last?.id == "workout-19")
  }

  @Test("Concurrent records remain linearizable across a suspended save")
  func concurrentRecordsDoNotLoseUpdates() async throws {
    let storage = SuspendedFirstSavePersonalizationStorage()
    let repository = PersonalizationRepository(storage: storage)

    let tennis = Task {
      try await repository.record(
        .verifiedWorkout(activity: .tennis, durationMinutes: 45, evidenceID: "tennis-1"),
        at: start
      )
    }
    await storage.waitUntilFirstSaveStarts()
    let swimming = Task {
      try await repository.record(
        .verifiedWorkout(activity: .swimming, durationMinutes: 40, evidenceID: "swimming-1"),
        at: start
      )
    }
    for _ in 0..<20 { await Task.yield() }
    await storage.releaseFirstSave()

    try await tennis.value
    try await swimming.value
    let state = try await repository.state(at: start)

    #expect(Set(state.memories.flatMap(\.evidence).map(\.id)) == ["tennis-1", "swimming-1"])
    #expect(state.owner.activityAffinities[.tennis] != nil)
    #expect(state.owner.activityAffinities[.swimming] != nil)
  }

  @Test("Clear, record, and toggle races preserve a valid serial order")
  func clearRecordToggleRaceIsLinearizable() async throws {
    let seededState = PersonalizationEngine().recording(
      .verifiedWorkout(activity: .tennis, durationMinutes: 45, evidenceID: "old-tennis"),
      in: PersonalizationState(),
      at: start
    )
    let storage = SuspendedFirstSavePersonalizationStorage(
      data: try PersonalizationStateCodec().encode(seededState)
    )
    let repository = PersonalizationRepository(storage: storage)

    let clear = Task {
      try await repository.clearLearnedData()
    }
    await storage.waitUntilFirstSaveStarts()
    let record = Task {
      try await repository.record(
        .verifiedWorkout(activity: .swimming, durationMinutes: 40, evidenceID: "new-swimming"),
        at: start
      )
    }
    let disable = Task {
      try await repository.setEnabled(false)
    }
    try await Task.sleep(for: .milliseconds(20))
    await storage.releaseFirstSave()

    try await clear.value
    try await record.value
    try await disable.value
    let state = try await repository.state(at: start)
    let evidenceIDs = Set(state.memories.flatMap(\.evidence).map(\.id))

    #expect(state.isEnabled == false)
    #expect(!evidenceIDs.contains("old-tennis"))
    #expect(evidenceIDs.isSubset(of: ["new-swimming"]))
  }
}

private struct PersonalizationFixtureMigration: PersonalizationStateMigrating {
  var output: Data

  func migrate(_ data: Data, from sourceVersion: Int, to targetVersion: Int) throws -> Data {
    #expect(String(data: data, encoding: .utf8)?.contains("legacyMemories") == true)
    #expect(sourceVersion == 0)
    #expect(targetVersion == 1)
    return output
  }
}

private actor SuspendedFirstSavePersonalizationStorage: PersonalizationStorage {
  private var data: Data?
  private var saveCount = 0
  private var firstSaveStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstSaveRelease: CheckedContinuation<Void, Never>?

  init(data: Data? = nil) {
    self.data = data
  }

  func load() -> Data? {
    data
  }

  func save(_ data: Data) async {
    saveCount += 1
    if saveCount == 1 {
      await withCheckedContinuation { continuation in
        firstSaveRelease = continuation
        firstSaveStarted = true
        for waiter in startWaiters {
          waiter.resume()
        }
        startWaiters.removeAll()
      }
    }
    self.data = data
  }

  func waitUntilFirstSaveStarts() async {
    guard !firstSaveStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func releaseFirstSave() {
    firstSaveRelease?.resume()
    firstSaveRelease = nil
  }
}
