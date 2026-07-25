import Foundation
import MoriDomain
import MoriPersistence
import Testing

@Suite("Profile-scoped Mori ledger")
struct ProfileLedgerTests {
  @Test("Codec is canonical and fixed-point replay resolves reordered dependencies")
  func canonicalReplay() throws {
    let state = try sampleState()
    let fact = factEnvelope(in: state, revision: revision(3), sequence: 2)
    let event = passiveEnvelope(in: state, revision: revision(2), sequence: 1)
    let ledger = try ProfileLedger(initialState: state, envelopes: [fact, event, fact])
    let codec = ProfileLedgerCodec()

    let firstBytes = try codec.encode(ledger)
    let restored = try codec.decode(firstBytes)
    let replay = restored.replay()

    #expect(restored.envelopes == [event, fact])
    #expect(try codec.encode(restored) == firstBytes)
    #expect(replay.unresolved.isEmpty)
    #expect(replay.state.derivedFacts.count == 1)
    #expect(replay.state.passiveEvents.count == 1)
    #expect(replay.state.experienceLedger.map(\.eventID) == [event.eventID, fact.eventID])
  }

  @Test("Authentic legacy Mock authority and ledger migrate to a runnable bootstrap")
  func legacyMockBootstrapLedgerMigration() async throws {
    let fixture = try legacyMockLedgerFixture()
    let codec = ProfileLedgerCodec()
    let migrated = try codec.decode(fixture.legacyData)
    let replay = migrated.replay()

    #expect(migrated.initialState.runtimeProfile == fixture.state.runtimeProfile)
    #expect(migrated.envelopes.first?.deletionEpoch == .bootstrap)
    #expect(replay.unresolved.isEmpty)
    #expect(replay.state.derivedFacts.count == 1)

    let storage = InMemoryProfileLedgerStorage(data: fixture.legacyData)
    let repository = ProfileLedgerRepository(
      storage: storage,
      initialState: fixture.state
    )
    #expect(try await repository.currentLedger() == migrated)
    #expect(await storage.load().data == fixture.normalizedData)
  }

  @Test("Paused legacy migration cannot overwrite a concurrent append")
  func migrationCASPreservesConcurrentAppend() async throws {
    let fixture = try legacyMockLedgerFixture()
    let storage = MigrationBarrierProfileLedgerStorage(
      data: fixture.legacyData
    )
    let migrating = ProfileLedgerRepository(
      storage: storage,
      initialState: fixture.state
    )
    let appending = ProfileLedgerRepository(
      storage: storage,
      initialState: fixture.state
    )
    let newEnvelope = mockFactEnvelope(
      id: "during-migration",
      evidenceID: "during-migration-steps",
      steps: 4_000,
      state: fixture.state,
      revision: LamportRevision(counter: 44, originDeviceID: "watch"),
      sequence: 2
    )

    let migration = Task {
      try await migrating.currentLedger()
    }
    await storage.waitUntilFirstSaveStarts()
    _ = try await appending.append(newEnvelope)
    await storage.resumeFirstSave()
    let migrated = try await migration.value
    let persisted = try ProfileLedgerCodec().decode(
      try #require(await storage.load().data)
    )

    #expect(
      Set(migrated.envelopes.map(\.eventID))
        == Set(persisted.envelopes.map(\.eventID))
    )
    #expect(persisted.envelopes.contains(newEnvelope))
    #expect(
      persisted.envelopes.allSatisfy {
        $0.deletionEpoch == .bootstrap
      }
    )
  }

  @Test("Independent repositories preserve both concurrent appends")
  func independentRepositoriesPreserveConcurrentAppends() async throws {
    let state = try sampleState()
    let initial = try ProfileLedgerCodec().encode(
      ProfileLedger(initialState: state)
    )
    let storage = MigrationBarrierProfileLedgerStorage(data: initial)
    let firstRepository = ProfileLedgerRepository(
      storage: storage,
      initialState: state
    )
    let secondRepository = ProfileLedgerRepository(
      storage: storage,
      initialState: state
    )
    let firstEnvelope = uniqueFactEnvelope(
      id: "independent-a",
      evidenceID: "independent-steps-a",
      stepTotal: 3_250,
      in: state,
      revision: revision(2),
      sequence: 1
    )
    let secondEnvelope = uniqueFactEnvelope(
      id: "independent-b",
      evidenceID: "independent-steps-b",
      stepTotal: 4_000,
      in: state,
      revision: revision(3),
      sequence: 2
    )

    let first = Task {
      try await firstRepository.append(firstEnvelope)
    }
    await storage.waitUntilFirstSaveStarts()
    _ = try await secondRepository.append(secondEnvelope)
    await storage.resumeFirstSave()
    _ = try await first.value
    let persisted = try ProfileLedgerCodec().decode(
      try #require(await storage.load().data)
    )

    #expect(
      Set(persisted.envelopes.map(\.eventID))
        == Set([firstEnvelope.eventID, secondEnvelope.eventID])
    )
  }

  @Test("Wrong profile, wrong epoch, and conflicting IDs fail closed")
  func scopeAndIdentityConflicts() throws {
    let state = try sampleState()
    var ledger = try ProfileLedger(initialState: state)
    let accepted = factEnvelope(in: state, revision: revision(2), sequence: 1)
    try ledger.append(accepted)

    var conflicting = factEnvelope(in: state, revision: revision(3), sequence: 2)
    conflicting = ExperienceSyncEnvelope(
      eventID: accepted.eventID,
      eventType: conflicting.eventType,
      profileID: conflicting.profileID,
      profileEpoch: conflicting.profileEpoch,
      deletionEpoch: conflicting.deletionEpoch,
      originDeviceID: conflicting.originDeviceID,
      originSequence: conflicting.originSequence,
      revision: conflicting.revision,
      observedAt: conflicting.observedAt,
      authoredAt: conflicting.authoredAt,
      privacyClass: conflicting.privacyClass,
      tombstone: conflicting.tombstone,
      sourceEventID: conflicting.sourceEventID,
      settlementID: conflicting.settlementID,
      payload: conflicting.payload
    )
    #expect(throws: ProfileLedgerError.conflictingEnvelopeID(accepted.eventID)) {
      try ledger.append(conflicting)
    }

    let otherState = try sampleState(profileID: "other")
    let wrongProfile = factEnvelope(in: otherState, revision: revision(4), sequence: 3)
    #expect(throws: ProfileLedgerError.envelopeProfileMismatch(wrongProfile.eventID)) {
      try ledger.append(wrongProfile)
    }
  }

  @Test("Ledger rejects a structurally valid envelope relabeled to another profile source")
  func rejectsRelabeledProfileSourceBeforePersistence() throws {
    let state = try sampleState()
    var ledger = try ProfileLedger(initialState: state)
    let valid = factEnvelope(in: state, revision: revision(2), sequence: 1)
    let relabeled = ExperienceSyncEnvelope(
      eventID: ExperienceEventID("relabeled-mock-source"),
      eventType: valid.eventType,
      profileID: valid.profileID,
      profileEpoch: valid.profileEpoch,
      deletionEpoch: valid.deletionEpoch,
      profileSource: .mock(
        scenarioID: MockScenarioID("ordinary-day"),
        selectionEpoch: valid.profileEpoch
      ),
      originDeviceID: valid.originDeviceID,
      originSequence: valid.originSequence,
      revision: valid.revision,
      observedAt: valid.observedAt,
      authoredAt: valid.authoredAt,
      privacyClass: valid.privacyClass,
      tombstone: valid.tombstone,
      sourceEventID: valid.sourceEventID,
      settlementID: valid.settlementID,
      payload: .derivedFact(
        DerivedFactRecord(
          header: header(EvidenceID("mock-steps"), in: state.runtimeProfile),
          observedAt: valid.observedAt ?? valid.authoredAt,
          freshUntil: valid.authoredAt.addingTimeInterval(3_600),
          value: .stepTotal(3_250),
          provenance: .deterministicMock
        )
      )
    )

    #expect(relabeled.validate() == nil)
    #expect(
      throws: ProfileLedgerError.envelopeProfileMismatch(relabeled.eventID)
    ) {
      try ledger.append(relabeled)
    }
    #expect(ledger.envelopes.isEmpty)
    #expect(ledger.replay().unresolved.isEmpty)
  }

  @Test("Repository persists exact duplicate once and survives relaunch")
  func repositoryRelaunch() async throws {
    let state = try sampleState()
    let storage = InMemoryProfileLedgerStorage()
    let first = ProfileLedgerRepository(storage: storage, initialState: state)
    let envelope = factEnvelope(in: state, revision: revision(2), sequence: 1)

    _ = try await first.append(envelope)
    _ = try await first.append(envelope)

    let second = ProfileLedgerRepository(storage: storage, initialState: state)
    let ledger = try await second.currentLedger()
    let replay = try await second.currentReplay()
    #expect(ledger.envelopes == [envelope])
    #expect(replay.state.derivedFacts.count == 1)
  }

  @Test("Repository serializes concurrent appends across suspended storage writes")
  func repositorySerializesConcurrentAppends() async throws {
    let state = try sampleState()
    let storage = PausingProfileLedgerStorage()
    let repository = ProfileLedgerRepository(storage: storage, initialState: state)
    let firstEnvelope = uniqueFactEnvelope(
      id: "concurrent-fact-a",
      evidenceID: "concurrent-steps-a",
      stepTotal: 3_250,
      in: state,
      revision: revision(2),
      sequence: 1
    )
    let secondEnvelope = uniqueFactEnvelope(
      id: "concurrent-fact-b",
      evidenceID: "concurrent-steps-b",
      stepTotal: 4_000,
      in: state,
      revision: revision(3),
      sequence: 2
    )

    let firstAppend = Task {
      try await repository.append(firstEnvelope)
    }
    await storage.waitUntilFirstSaveStarts()

    let secondAppend = Task {
      await storage.markSecondAppendStarted()
      return try await repository.append(secondEnvelope)
    }
    await storage.waitUntilSecondAppendStarts()

    for _ in 0..<1_000 {
      if await storage.saveCount > 1 { break }
      await Task.yield()
    }
    #expect(await storage.saveCount == 1)

    await storage.resumeFirstSave()
    _ = try await firstAppend.value
    _ = try await secondAppend.value

    let persistedData = try #require(await storage.persistedData)
    let persistedLedger = try ProfileLedgerCodec().decode(persistedData)
    let currentLedger = try await repository.currentLedger()
    #expect(persistedLedger.envelopes == [firstEnvelope, secondEnvelope])
    #expect(currentLedger.envelopes == [firstEnvelope, secondEnvelope])
  }

  @Test("Malformed persisted bytes fail closed")
  func malformedBytes() async throws {
    let state = try sampleState()
    let storage = InMemoryProfileLedgerStorage(data: Data("not-json".utf8))
    let repository = ProfileLedgerRepository(storage: storage, initialState: state)

    await #expect(throws: (any Error).self) {
      _ = try await repository.currentLedger()
    }
  }

  @Test("Initial state cannot smuggle replayable product records around the ledger")
  func initialStateMustBeBaseline() throws {
    let baseline = try sampleState()
    guard
      case .derivedFact(let fact) = factEnvelope(
        in: baseline,
        revision: revision(2),
        sequence: 1
      ).payload
    else {
      Issue.record("fixture must contain a derived fact")
      return
    }
    let seeded = ProfileState(
      header: baseline.header,
      runtimeProfile: baseline.runtimeProfile,
      companionSensingEnabled: baseline.companionSensingEnabled,
      currentSensingEpoch: baseline.currentSensingEpoch,
      selectedIdentity: baseline.selectedIdentity,
      identityRevision: baseline.identityRevision,
      tone: baseline.tone,
      derivedFacts: [fact],
      coinLedger: baseline.coinLedger,
      collection: baseline.collection
    )

    #expect(throws: ProfileLedgerError.initialStateContainsProductRecords) {
      _ = try ProfileLedger(initialState: seeded)
    }
  }

  @Test("File storage creates a protected, non-backup artifact")
  func fileStorage() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mori-ledger-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("profile-ledger-v1.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = FileProfileLedgerStorage(fileURL: fileURL)
    let state = try sampleState()
    let repository = ProfileLedgerRepository(storage: storage, initialState: state)

    _ = try await repository.append(
      factEnvelope(in: state, revision: revision(2), sequence: 1)
    )

    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    #expect(
      try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    )
  }

  @Test("Independent file storage instances preserve concurrent appends")
  func fileStorageCASPreservesConcurrentAppends() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "mori-ledger-cas-\(UUID().uuidString)",
        isDirectory: true
      )
    let fileURL = directory.appendingPathComponent("profile-ledger-v1.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = try sampleState()
    let first = ProfileLedgerRepository(
      storage: FileProfileLedgerStorage(fileURL: fileURL),
      initialState: state
    )
    let second = ProfileLedgerRepository(
      storage: FileProfileLedgerStorage(fileURL: fileURL),
      initialState: state
    )
    let firstEnvelope = uniqueFactEnvelope(
      id: "file-cas-a",
      evidenceID: "file-cas-steps-a",
      stepTotal: 3_250,
      in: state,
      revision: revision(2),
      sequence: 1
    )
    let secondEnvelope = uniqueFactEnvelope(
      id: "file-cas-b",
      evidenceID: "file-cas-steps-b",
      stepTotal: 4_000,
      in: state,
      revision: revision(3),
      sequence: 2
    )

    async let firstResult = first.append(firstEnvelope)
    async let secondResult = second.append(secondEnvelope)
    _ = try await (firstResult, secondResult)

    let reopened = ProfileLedgerRepository(
      storage: FileProfileLedgerStorage(fileURL: fileURL),
      initialState: state
    )
    let persisted = try await reopened.currentLedger()
    #expect(
      Set(persisted.envelopes.map(\.eventID))
        == Set([firstEnvelope.eventID, secondEnvelope.eventID])
    )
  }

  @Test("File storage instances reject a stale expected revision")
  func fileStorageRejectsStaleRevision() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "mori-ledger-stale-\(UUID().uuidString)",
        isDirectory: true
      )
    let fileURL = directory.appendingPathComponent("profile-ledger-v1.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = FileProfileLedgerStorage(fileURL: fileURL)
    let stale = FileProfileLedgerStorage(fileURL: fileURL)
    let firstRevision = try await first.load().revision
    let staleRevision = try await stale.load().revision

    _ = try await first.save(
      Data("first".utf8),
      replacing: firstRevision
    )
    await #expect(throws: ProfileLedgerStorageError.staleRevision) {
      _ = try await stale.save(
        Data("stale".utf8),
        replacing: staleRevision
      )
    }
    #expect(try await first.load().data == Data("first".utf8))
  }

  @Test("Valid terminal losers are consumed instead of remaining unresolved")
  func terminalLosersConverge() throws {
    let state = try sampleState()
    let profile = state.runtimeProfile
    let now = Date(timeIntervalSince1970: 1_700_000_100)
    let event = passiveEnvelope(in: state, revision: revision(3), sequence: 2)
    let presented = PassiveEventTransition(
      header: header(EventTransitionID("presented"), in: profile),
      eventID: EventID("walk"),
      revision: revision(4),
      state: .presented(at: now.addingTimeInterval(1))
    )
    let expiredReminder = PassiveEventTransition(
      header: header(EventTransitionID("expired-loser"), in: profile),
      eventID: EventID("walk"),
      revision: revision(5),
      state: .expired(at: now.addingTimeInterval(130))
    )
    let task = TaskInstance(
      header: header(TaskID("walk-task"), in: profile),
      sourceEventID: EventID("walk"),
      kind: .walkTogether,
      cooldownKey: TaskCooldownKey("walk"),
      recommendationPriority: .recommended,
      completionPolicy: .automatic,
      issuedAt: now.addingTimeInterval(10),
      issuedRevision: revision(6),
      cooldownDuration: 900,
      expiresAt: now.addingTimeInterval(300),
      rewardTier: .standard,
      settlementID: TaskSettlementID("walk-settlement"),
      lifecycleRevision: revision(6)
    )
    let completed = TaskTransition(
      header: header(TaskTransitionID("completed"), in: profile),
      taskID: task.header.recordID,
      revision: revision(7),
      state: .completed(method: .automatic, at: now.addingTimeInterval(20)),
      settlementID: task.settlementID
    )
    let expiredTask = TaskTransition(
      header: header(TaskTransitionID("task-expired-loser"), in: profile),
      taskID: task.header.recordID,
      revision: revision(8),
      state: .expired(at: now.addingTimeInterval(301)),
      settlementID: nil
    )
    let localDay = LocalDay("2023-11-14")
    let memoryID = MemoryID.daily(
      profileID: profile.id,
      profileEpoch: profile.epoch,
      localDay: localDay,
      timeZoneIdentifier: "UTC"
    )
    let memory = MemoryRecord(
      header: header(memoryID, in: profile),
      localDay: localDay,
      timeZoneIdentifier: "UTC",
      authoredRevision: revision(9),
      lifecycle: .sealed(
        SealedMemoryContent(
          facts: [
            MemoryFactReference(
              evidenceID: EvidenceID("steps"),
              kind: .stepSummary,
              sourceEventID: EventID("walk")
            )
          ],
          narrative: "今天我们经过了一段很长的路。",
          sceneID: "spring-valley",
          moriActionID: "rest.sit",
          sealedAt: now.addingTimeInterval(40)
        )
      )
    )
    let firstDelete = MemoryTransition(
      header: header(MemoryTransitionID("memory-delete"), in: profile),
      memoryID: memoryID,
      revision: revision(10),
      kind: .delete(at: now.addingTimeInterval(50))
    )
    let repeatedDelete = MemoryTransition(
      header: header(MemoryTransitionID("memory-delete-loser"), in: profile),
      memoryID: memoryID,
      revision: revision(11),
      kind: .delete(at: now.addingTimeInterval(51))
    )
    let envelopes = [
      factEnvelope(in: state, revision: revision(2), sequence: 1),
      event,
      terminalEnvelope(
        id: "presented-envelope",
        sequence: 3,
        payload: .passiveEventTransition(presented),
        profile: profile
      ),
      terminalEnvelope(
        id: "expired-reminder-envelope",
        sequence: 4,
        payload: .passiveEventTransition(expiredReminder),
        profile: profile
      ),
      terminalEnvelope(
        id: "task-envelope",
        sequence: 5,
        payload: .task(task),
        profile: profile,
        sourceEventID: task.sourceEventID,
        settlementID: task.settlementID
      ),
      terminalEnvelope(
        id: "completed-envelope",
        sequence: 6,
        payload: .taskTransition(completed),
        profile: profile,
        settlementID: task.settlementID
      ),
      terminalEnvelope(
        id: "expired-task-envelope",
        sequence: 7,
        payload: .taskTransition(expiredTask),
        profile: profile
      ),
      terminalEnvelope(
        id: "memory-envelope",
        sequence: 8,
        payload: .memory(memory),
        profile: profile
      ),
      terminalEnvelope(
        id: "memory-delete-envelope",
        sequence: 9,
        payload: .memoryTransition(firstDelete),
        profile: profile,
        tombstoneTarget: memoryID.rawValue
      ),
      terminalEnvelope(
        id: "memory-delete-loser-envelope",
        sequence: 10,
        payload: .memoryTransition(repeatedDelete),
        profile: profile,
        tombstoneTarget: memoryID.rawValue
      ),
    ]

    let replay = try ProfileLedger(initialState: state, envelopes: envelopes).replay()

    #expect(replay.unresolved.isEmpty)
    #expect(replay.state.passiveEvents.first?.reminderState == presented.state)
    #expect(replay.state.tasks.first?.lifecycle == completed.state)
    #expect(replay.state.memories.first?.lifecycle.isDeleted == true)
  }

  @Test(
    "A transition causally earlier than task issuance remains rejected without corrupting state")
  func taskTransitionBeforeIssuanceFailsClosed() throws {
    let state = try sampleState()
    let profile = state.runtimeProfile
    let now = Date(timeIntervalSince1970: 1_700_000_100)
    let event = passiveEnvelope(in: state, revision: revision(3), sequence: 2)
    let task = TaskInstance(
      header: header(TaskID("causal-task"), in: profile),
      sourceEventID: EventID("walk"),
      kind: .walkTogether,
      cooldownKey: TaskCooldownKey("walk"),
      recommendationPriority: .recommended,
      completionPolicy: .automatic,
      issuedAt: now,
      issuedRevision: revision(10),
      cooldownDuration: 900,
      expiresAt: now.addingTimeInterval(300),
      rewardTier: .standard,
      settlementID: TaskSettlementID("causal-settlement"),
      lifecycleRevision: revision(10)
    )
    let impossibleCompletion = TaskTransition(
      header: header(TaskTransitionID("pre-issuance"), in: profile),
      taskID: task.header.recordID,
      revision: revision(4),
      state: .completed(method: .automatic, at: now.addingTimeInterval(20)),
      settlementID: task.settlementID
    )
    let ledger = try ProfileLedger(
      initialState: state,
      envelopes: [
        factEnvelope(in: state, revision: revision(2), sequence: 1),
        event,
        terminalEnvelope(
          id: "pre-issuance-completion",
          sequence: 3,
          payload: .taskTransition(impossibleCompletion),
          profile: profile,
          settlementID: task.settlementID
        ),
        terminalEnvelope(
          id: "causal-task",
          sequence: 9,
          payload: .task(task),
          profile: profile,
          sourceEventID: task.sourceEventID,
          settlementID: task.settlementID
        ),
      ]
    )

    let replay = ledger.replay()
    #expect(replay.unresolved.count == 1)
    #expect(replay.unresolved.first?.reason == .invalidRecord)
    #expect(replay.state.tasks.first?.lifecycle == .active)
    #expect(replay.state.validate() == nil)
  }

  @Test("A genuinely late completion after expiry is a consumed terminal loser")
  func lateCompletionAfterExpiryConverges() throws {
    let state = try sampleState()
    let profile = state.runtimeProfile
    let now = Date(timeIntervalSince1970: 1_700_000_100)
    let task = TaskInstance(
      header: header(TaskID("expiring-task"), in: profile),
      sourceEventID: EventID("walk"),
      kind: .walkTogether,
      cooldownKey: TaskCooldownKey("walk"),
      recommendationPriority: .recommended,
      completionPolicy: .automatic,
      issuedAt: now,
      issuedRevision: revision(4),
      cooldownDuration: 900,
      expiresAt: now.addingTimeInterval(10),
      rewardTier: .standard,
      settlementID: TaskSettlementID("expiring-settlement"),
      lifecycleRevision: revision(4)
    )
    let expiry = TaskTransition(
      header: header(TaskTransitionID("expiry-winner"), in: profile),
      taskID: task.header.recordID,
      revision: revision(5),
      state: .expired(at: now.addingTimeInterval(10)),
      settlementID: nil
    )
    let lateCompletion = TaskTransition(
      header: header(TaskTransitionID("late-completion-loser"), in: profile),
      taskID: task.header.recordID,
      revision: revision(6),
      state: .completed(method: .automatic, at: now.addingTimeInterval(11)),
      settlementID: task.settlementID
    )
    let ledger = try ProfileLedger(
      initialState: state,
      envelopes: [
        factEnvelope(in: state, revision: revision(2), sequence: 1),
        passiveEnvelope(in: state, revision: revision(3), sequence: 2),
        terminalEnvelope(
          id: "expiring-task",
          sequence: 3,
          payload: .task(task),
          profile: profile,
          sourceEventID: task.sourceEventID,
          settlementID: task.settlementID
        ),
        terminalEnvelope(
          id: "expiry-winner",
          sequence: 4,
          payload: .taskTransition(expiry),
          profile: profile
        ),
        terminalEnvelope(
          id: "late-completion-loser",
          sequence: 5,
          payload: .taskTransition(lateCompletion),
          profile: profile,
          settlementID: task.settlementID
        ),
      ]
    )

    let replay = ledger.replay()
    #expect(replay.unresolved.isEmpty)
    #expect(replay.state.tasks.first?.lifecycle == expiry.state)
    #expect(replay.state.validate() == nil)
  }
}

@Suite("Experience envelope privacy codec")
struct ExperienceEnvelopePrivacyCodecTests {
  @Test("Mock welcome grant round-trips as a closed canonical event")
  func welcomeGrantRoundTrip() throws {
    let epoch = ProfileEpoch(revision(7))
    let profile = RuntimeProfile(
      id: ProfileID("mock-welcome"),
      epoch: epoch,
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("mock-welcome-delete"),
        revision: revision(1)
      ),
      source: .mock(
        scenarioID: MockScenarioID("normal-day"),
        selectionEpoch: epoch
      )
    )
    let transaction = CoinTransaction(
      header: header(CoinTransactionID("mock-welcome-v1"), in: profile),
      revision: LamportRevision(
        counter: 8,
        originDeviceID: "mock-bootstrap"
      ),
      authoredAt: Date(timeIntervalSince1970: 1_700_000_000),
      direction: .credit,
      amount: 18,
      reason: .welcomeGrant(schemaVersion: 1)
    )
    let envelope = ExperienceSyncEnvelope(
      eventID: ExperienceEventID("mock-welcome-event-v1"),
      eventType: .coinWelcomeGranted,
      profileID: profile.id,
      profileEpoch: profile.epoch,
      deletionEpoch: profile.deletionEpoch,
      profileSource: profile.source,
      originDeviceID: "mock-bootstrap",
      originSequence: 1,
      revision: transaction.revision,
      observedAt: nil,
      authoredAt: transaction.authoredAt,
      privacyClass: .productState,
      tombstone: nil,
      sourceEventID: nil,
      settlementID: nil,
      payload: .coinTransaction(transaction)
    )
    let codec = ExperienceEnvelopeCodec()
    let data = try codec.encode(envelope)

    #expect(envelope.validate() == nil)
    #expect(try codec.decode(data) == envelope)
    #expect(try codec.encode(codec.decode(data)) == data)
  }

  @Test("Approved envelope round-trips as canonical bytes")
  func roundTrip() throws {
    let state = try sampleState()
    let envelope = factEnvelope(in: state, revision: revision(2), sequence: 1)
    let codec = ExperienceEnvelopeCodec()

    let data = try codec.encode(envelope)

    #expect(try codec.decode(data) == envelope)
    #expect(try codec.encode(codec.decode(data)) == data)
  }

  @Test("Injected raw route and health keys are rejected before decoding")
  func forbiddenRawKeys() throws {
    let state = try sampleState()
    let data = try ExperienceEnvelopeCodec().encode(
      factEnvelope(in: state, revision: revision(2), sequence: 1)
    )
    var object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["preciseLocation"] = ["latitude": 31.2, "longitude": 121.5]
    let injected = try JSONSerialization.data(withJSONObject: object)

    #expect(
      throws: ExperienceEnvelopeCodecError.forbiddenPayloadKey("preciseLocation")
    ) {
      _ = try ExperienceEnvelopeCodec().decode(injected)
    }
  }

  @Test("Oversized experience payloads fail closed")
  func oversized() throws {
    let state = try sampleState()
    let envelope = factEnvelope(in: state, revision: revision(2), sequence: 1)

    #expect(throws: ExperienceEnvelopeCodecError.self) {
      _ = try ExperienceEnvelopeCodec(maximumBytes: 32).encode(envelope)
    }
  }
}

@Suite("Version-one golden schema fixtures")
struct GoldenSchemaFixtureTests {
  @Test("Experience envelope fixture remains decodable and canonical")
  func experienceEnvelope() throws {
    let data = try canonicalFixture("experience-envelope-v1")
    let codec = ExperienceEnvelopeCodec()
    let envelope = try codec.decode(data)
    #expect(try codec.encode(envelope) == data)
  }

  @Test("Profile ledger fixture remains decodable and canonical")
  func profileLedger() throws {
    let data = try canonicalFixture("profile-ledger-v1")
    let codec = ProfileLedgerCodec()
    let ledger = try codec.decode(data)
    #expect(try codec.encode(ledger) == data)
    #expect(ledger.replay().unresolved.isEmpty)
  }

  @Test("Reset bundle fixture preserves the exact empty-authority baseline")
  func resetBundle() throws {
    let data = try canonicalFixture("reset-bundle-v1")
    let codec = CanonicalJSONCodec()
    let bundle = try codec.decode(LegacyResetBundle.self, from: data)
    #expect(bundle.schemaVersion == LegacyResetBundle.currentSchemaVersion)
    #expect(bundle.marker.resetVersion == LegacyResetMarker.currentResetVersion)
    #expect(bundle.profileLedger.envelopes.isEmpty)
    #expect(bundle.profileLedger.replay().state.coinLedger.balance == 0)
    #expect(bundle.profileLedger.replay().state.derivedFacts.isEmpty)
    #expect(bundle.profileLedger.replay().state.tasks.isEmpty)
    #expect(bundle.profileLedger.replay().state.memories.isEmpty)
    #expect(try codec.encode(bundle) == data)
  }
}

@Suite("Atomic legacy reset bundle")
struct LegacyResetCoordinatorTests {
  @Test("Bundle is durable before legacy stores are purged and relaunch is idempotent")
  func applyAndRelaunch() async throws {
    let source = InMemoryLegacyResetSourceStorage(
      snapshot: LegacyResetSourceSnapshot(
        progressionData: try fixture("valid-progression"),
        preferencesData: try fixture("valid-preferences")
      )
    )
    let destination = InMemoryLegacyResetBundleStorage()
    let coordinator = LegacyResetCoordinator(source: source, destination: destination)
    let scope = try LegacyStoreScope(kind: .real, storeKey: "real")
    let state = try sampleState()

    guard
      case .applied(let bundle) = try await coordinator.run(
        scope: scope,
        initialState: state
      )
    else {
      Issue.record("expected first reset to apply")
      return
    }
    #expect(bundle.profileLedger.envelopes.isEmpty)
    #expect(bundle.profileLedger.replay().state.coinLedger.balance == 0)
    #expect(bundle.profileLedger.replay().state.tasks.isEmpty)
    #expect(bundle.profileLedger.replay().state.memories.isEmpty)
    #expect(await source.purgeCount == 1)

    let relaunched = LegacyResetCoordinator(source: source, destination: destination)
    guard
      case .alreadyApplied = try await relaunched.run(
        scope: scope,
        initialState: state
      )
    else {
      Issue.record("expected persisted marker to make relaunch idempotent")
      return
    }
    #expect(await source.purgeCount == 2)
  }

  @Test("A failed destination write never purges legacy bytes")
  func destinationFailure() async throws {
    let source = InMemoryLegacyResetSourceStorage(
      snapshot: LegacyResetSourceSnapshot(
        progressionData: try fixture("valid-progression"),
        preferencesData: nil
      )
    )
    let coordinator = LegacyResetCoordinator(
      source: source,
      destination: AlwaysFailingResetDestination()
    )

    await #expect(throws: ResetFailure.write) {
      _ = try await coordinator.run(
        scope: try LegacyStoreScope(kind: .real, storeKey: "real"),
        initialState: try sampleState()
      )
    }
    #expect(await source.purgeCount == 0)
    #expect(await source.loadSnapshot().progressionData != nil)
  }

  @Test("Future legacy schema is preserved without a bundle or purge")
  func futureSchema() async throws {
    let source = InMemoryLegacyResetSourceStorage(
      snapshot: LegacyResetSourceSnapshot(
        progressionData: try fixture("future-progression"),
        preferencesData: nil
      )
    )
    let destination = InMemoryLegacyResetBundleStorage()
    let coordinator = LegacyResetCoordinator(source: source, destination: destination)

    let result = try await coordinator.run(
      scope: try LegacyStoreScope(kind: .real, storeKey: "real"),
      initialState: try sampleState()
    )
    #expect(result == .blocked(.futureProgressionSchema(99)))
    #expect(await source.purgeCount == 0)
    #expect(await destination.load() == nil)
  }
}

private enum ResetFailure: Error {
  case write
}

private actor AlwaysFailingResetDestination: LegacyResetBundleStorage {
  func load() -> Data? { nil }
  func save(_: Data) throws { throw ResetFailure.write }
}

private actor PausingProfileLedgerStorage: ProfileLedgerStorage {
  private(set) var persistedData: Data?
  private(set) var saveCount = 0
  private var firstSaveStarted = false
  private var firstSaveStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstSaveResume: CheckedContinuation<Void, Never>?
  private var secondAppendStarted = false
  private var secondAppendStartWaiters: [CheckedContinuation<Void, Never>] = []

  func load() -> ProfileLedgerStorageSnapshot {
    ProfileLedgerStorageSnapshot(
      data: persistedData,
      revision: .current(for: persistedData)
    )
  }

  func save(
    _ data: Data,
    replacing expectedRevision: ProfileLedgerStorageRevision
  ) async throws -> ProfileLedgerStorageRevision {
    saveCount += 1
    if saveCount == 1 {
      firstSaveStarted = true
      let waiters = firstSaveStartWaiters
      firstSaveStartWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        firstSaveResume = continuation
      }
    }
    guard ProfileLedgerStorageRevision.current(for: persistedData) == expectedRevision else {
      throw ProfileLedgerStorageError.staleRevision
    }
    persistedData = data
    return .current(for: data)
  }

  func waitUntilFirstSaveStarts() async {
    guard !firstSaveStarted else { return }
    await withCheckedContinuation { continuation in
      firstSaveStartWaiters.append(continuation)
    }
  }

  func resumeFirstSave() {
    firstSaveResume?.resume()
    firstSaveResume = nil
  }

  func markSecondAppendStarted() {
    secondAppendStarted = true
    let waiters = secondAppendStartWaiters
    secondAppendStartWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func waitUntilSecondAppendStarts() async {
    guard !secondAppendStarted else { return }
    await withCheckedContinuation { continuation in
      secondAppendStartWaiters.append(continuation)
    }
  }
}

private actor MigrationBarrierProfileLedgerStorage: ProfileLedgerStorage {
  private var data: Data?
  private var saveCount = 0
  private var firstSaveStarted = false
  private var firstSaveWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstSaveResume: CheckedContinuation<Void, Never>?

  init(data: Data?) {
    self.data = data
  }

  func load() -> ProfileLedgerStorageSnapshot {
    ProfileLedgerStorageSnapshot(
      data: data,
      revision: .current(for: data)
    )
  }

  func save(
    _ data: Data,
    replacing expectedRevision: ProfileLedgerStorageRevision
  ) async throws -> ProfileLedgerStorageRevision {
    saveCount += 1
    if saveCount == 1 {
      firstSaveStarted = true
      let waiters = firstSaveWaiters
      firstSaveWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        firstSaveResume = continuation
      }
    }
    guard ProfileLedgerStorageRevision.current(for: self.data) == expectedRevision else {
      throw ProfileLedgerStorageError.staleRevision
    }
    self.data = data
    return .current(for: data)
  }

  func waitUntilFirstSaveStarts() async {
    guard !firstSaveStarted else { return }
    await withCheckedContinuation { continuation in
      firstSaveWaiters.append(continuation)
    }
  }

  func resumeFirstSave() {
    firstSaveResume?.resume()
    firstSaveResume = nil
  }
}

private func sampleState(profileID: String = "real") throws -> ProfileState {
  let profile = RuntimeProfile(
    id: ProfileID(profileID),
    epoch: ProfileEpoch(revision(1)),
    deletionEpoch: DeletionEpoch(
      requestID: DeletionRequestID("initial-delete-fence"),
      revision: revision(1)
    ),
    source: .real
  )
  return try emptyState(profile: profile)
}

private func emptyState(profile: RuntimeProfile) throws -> ProfileState {
  let state = ProfileState(
    header: header(profile.id, in: profile),
    runtimeProfile: profile,
    companionSensingEnabled: true,
    currentSensingEpoch: SensingEpoch(revision(1)),
    selectedIdentity: .penguin,
    identityRevision: revision(1),
    coinLedger: CoinLedger(
      header: header(CoinLedgerID("coins"), in: profile)
    ),
    collection: CollectionState(
      header: header(CollectionID("collection"), in: profile)
    )
  )
  if let rejection = state.validate() {
    throw rejection
  }
  return state
}

private struct LegacyMockLedgerFixture {
  let state: ProfileState
  let normalizedData: Data
  let legacyData: Data
}

private func legacyMockLedgerFixture() throws -> LegacyMockLedgerFixture {
  let scenarioID = MockScenarioID("ordinary-day")
  let selectionRevision = LamportRevision(
    counter: 42,
    originDeviceID: "watch"
  )
  let epoch = ProfileEpoch(selectionRevision)
  let profile = RuntimeProfile(
    id: MockProfileBootstrapMigration.derivedProfileID(
      scenarioID: scenarioID,
      revision: selectionRevision
    ),
    epoch: epoch,
    deletionEpoch: .bootstrap,
    source: .mock(
      scenarioID: scenarioID,
      selectionEpoch: epoch
    )
  )
  let state = try emptyState(profile: profile)
  let envelope = mockFactEnvelope(
    id: "legacy-mock-event",
    evidenceID: "legacy-mock-steps",
    steps: 3_250,
    state: state,
    revision: LamportRevision(counter: 43, originDeviceID: "watch"),
    sequence: 1
  )
  let normalizedData = try ProfileLedgerCodec().encode(
    ProfileLedger(initialState: state, envelopes: [envelope])
  )
  let legacyEpoch = DeletionEpoch(
    requestID:
      MockProfileBootstrapMigration.legacyDeletionRequestID(
        scenarioID: scenarioID,
        revision: selectionRevision
      ),
    revision: selectionRevision
  )
  return try LegacyMockLedgerFixture(
    state: state,
    normalizedData: normalizedData,
    legacyData: replacingDeletionEpochs(
      in: normalizedData,
      from: .bootstrap,
      to: legacyEpoch
    )
  )
}

private func mockFactEnvelope(
  id: String,
  evidenceID: String,
  steps: Int,
  state: ProfileState,
  revision: LamportRevision,
  sequence: UInt64
) -> ExperienceSyncEnvelope {
  let profile = state.runtimeProfile
  let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
  let fact = DerivedFactRecord(
    header: header(EvidenceID(evidenceID), in: profile),
    observedAt: observedAt,
    freshUntil: observedAt.addingTimeInterval(3_600),
    value: .stepTotal(steps),
    provenance: .deterministicMock,
    authorization: .companion(state.currentSensingEpoch)
  )
  return ExperienceSyncEnvelope(
    eventID: ExperienceEventID(id),
    eventType: .derivedFact,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    profileSource: profile.source,
    originDeviceID: revision.originDeviceID,
    originSequence: sequence,
    revision: revision,
    observedAt: observedAt,
    authoredAt: observedAt,
    privacyClass: .approvedDerived,
    tombstone: nil,
    sourceEventID: nil,
    settlementID: nil,
    payload: .derivedFact(fact)
  )
}

private func replacingDeletionEpochs(
  in data: Data,
  from sourceEpoch: DeletionEpoch,
  to replacementEpoch: DeletionEpoch
) throws -> Data {
  let codec = CanonicalJSONCodec()
  let source = try JSONSerialization.jsonObject(
    with: codec.encode(sourceEpoch)
  )
  let replacement = try JSONSerialization.jsonObject(
    with: codec.encode(replacementEpoch)
  )
  let root = try JSONSerialization.jsonObject(with: data)
  let migrated = replaceDeletionEpochs(
    in: root,
    matching: source,
    with: replacement
  )
  return try JSONSerialization.data(
    withJSONObject: migrated,
    options: [.sortedKeys]
  )
}

private func replaceDeletionEpochs(
  in value: Any,
  matching sourceEpoch: Any,
  with replacementEpoch: Any
) -> Any {
  if let object = value as? [String: Any] {
    return Dictionary(
      uniqueKeysWithValues: object.map { key, child in
        if key == "deletionEpoch",
          (child as AnyObject).isEqual(sourceEpoch)
        {
          return (key, replacementEpoch)
        }
        return (
          key,
          replaceDeletionEpochs(
            in: child,
            matching: sourceEpoch,
            with: replacementEpoch
          )
        )
      }
    )
  }
  if let array = value as? [Any] {
    return array.map {
      replaceDeletionEpochs(
        in: $0,
        matching: sourceEpoch,
        with: replacementEpoch
      )
    }
  }
  return value
}

private func factEnvelope(
  in state: ProfileState,
  revision: LamportRevision,
  sequence: UInt64
) -> ExperienceSyncEnvelope {
  uniqueFactEnvelope(
    id: "experience-fact",
    evidenceID: "steps",
    stepTotal: 3_250,
    in: state,
    revision: revision,
    sequence: sequence
  )
}

private func uniqueFactEnvelope(
  id: String,
  evidenceID: String,
  stepTotal: Int,
  in state: ProfileState,
  revision: LamportRevision,
  sequence: UInt64
) -> ExperienceSyncEnvelope {
  let profile = state.runtimeProfile
  let fact = DerivedFactRecord(
    header: header(EvidenceID(evidenceID), in: profile),
    observedAt: Date(timeIntervalSince1970: 1_700_000_000),
    freshUntil: Date(timeIntervalSince1970: 1_700_003_600),
    value: .stepTotal(stepTotal),
    provenance: .healthSummary,
    authorization: .companion(state.currentSensingEpoch)
  )
  return ExperienceSyncEnvelope(
    eventID: ExperienceEventID(id),
    eventType: .derivedFact,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    originDeviceID: revision.originDeviceID,
    originSequence: sequence,
    revision: revision,
    observedAt: fact.observedAt,
    authoredAt: fact.observedAt,
    privacyClass: .approvedDerived,
    tombstone: nil,
    sourceEventID: nil,
    settlementID: nil,
    payload: .derivedFact(fact)
  )
}

private func passiveEnvelope(
  in state: ProfileState,
  revision: LamportRevision,
  sequence: UInt64
) -> ExperienceSyncEnvelope {
  let profile = state.runtimeProfile
  let event = PassiveCompanionEvent(
    header: header(EventID("walk"), in: profile),
    sensingEpoch: state.currentSensingEpoch,
    kind: .sharedWalk,
    observedAt: Date(timeIntervalSince1970: 1_700_000_100),
    confidence: .high,
    evidence: [EvidenceReference(id: EvidenceID("steps"), kind: .stepSummary)],
    presentationDeadline: Date(timeIntervalSince1970: 1_700_000_220),
    replacementKey: "movement",
    taskCooldownKey: TaskCooldownKey("walk"),
    memoryEligibility: .eligible,
    sceneID: "spring_valley",
    moriActionID: "walk_together",
    reminderRevision: revision
  )
  return ExperienceSyncEnvelope(
    eventID: ExperienceEventID("experience-walk"),
    eventType: .passiveEvent,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    originDeviceID: revision.originDeviceID,
    originSequence: sequence,
    revision: revision,
    observedAt: event.observedAt,
    authoredAt: event.observedAt,
    privacyClass: .approvedDerived,
    tombstone: nil,
    sourceEventID: nil,
    settlementID: nil,
    payload: .passiveEvent(event)
  )
}

private func terminalEnvelope(
  id: String,
  sequence: UInt64,
  payload: ExperienceSyncPayload,
  profile: RuntimeProfile,
  sourceEventID: EventID? = nil,
  settlementID: TaskSettlementID? = nil,
  tombstoneTarget: String? = nil
) -> ExperienceSyncEnvelope {
  let authoredAt = Date(timeIntervalSince1970: 1_700_000_100 + Double(sequence))
  return ExperienceSyncEnvelope(
    eventID: ExperienceEventID(id),
    eventType: payload.eventType,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    profileSource: profile.source,
    originDeviceID: "iphone",
    originSequence: sequence,
    revision: revision(sequence + 1),
    observedAt: nil,
    authoredAt: authoredAt,
    privacyClass: payload.expectedPrivacyClass,
    tombstone: tombstoneTarget.map {
      ExperienceTombstone(targetRecordID: $0, reason: .userDeleted)
    },
    sourceEventID: sourceEventID,
    settlementID: settlementID,
    payload: payload
  )
}

private func header<ID>(
  _ id: ID,
  in profile: RuntimeProfile
) -> ProfileScopedRecordHeader<ID> where ID: Codable & Hashable & Sendable {
  ProfileScopedRecordHeader(
    recordID: id,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch
  )
}

private func revision(_ counter: UInt64) -> LamportRevision {
  LamportRevision(counter: counter, originDeviceID: "iphone")
}

private func fixture(_ name: String) throws -> Data {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: "json")
  )
  return try Data(contentsOf: url)
}

private func canonicalFixture(_ name: String) throws -> Data {
  var data = try fixture(name)
  while data.last == 0x0A || data.last == 0x0D {
    data.removeLast()
  }
  return data
}
