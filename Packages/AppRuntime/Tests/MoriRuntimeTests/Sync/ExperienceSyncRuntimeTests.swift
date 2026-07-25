import Foundation
import MoriDomain
import MoriPersistence
import MoriRuntime
import Testing

@Suite("Automatic experience-event synchronization")
struct ExperienceSyncRuntimeTests {
  @Test("Offline retry survives relaunch and converges without a user sync action")
  func offlineRetryAndRelaunch() async throws {
    let profile = mockProfile()
    let phoneState = try baselineState(profile: profile)
    let watchState = try baselineState(profile: profile)
    let phoneLedgerStorage = InMemoryProfileLedgerStorage()
    let watchLedgerStorage = InMemoryProfileLedgerStorage()
    let outboxStorage = InMemoryExperienceSyncOutboxStorage()
    let phoneLedger = ProfileLedgerRepository(
      storage: phoneLedgerStorage,
      initialState: phoneState
    )
    let watchLedger = ProfileLedgerRepository(
      storage: watchLedgerStorage,
      initialState: watchState
    )
    let firstPhone = ExperienceSyncRuntime(
      profile: profile,
      outboxStorage: outboxStorage,
      ledger: phoneLedger
    )
    let watch = ExperienceSyncRuntime(
      profile: profile,
      outboxStorage: InMemoryExperienceSyncOutboxStorage(),
      ledger: watchLedger
    )
    let event = factEnvelope(
      id: "offline-steps",
      evidenceID: "offline-steps-fact",
      steps: 3_250,
      profile: profile,
      revision: revision(2, origin: "phone"),
      sequence: 1
    )

    try await firstPhone.recordLocal(event)
    await #expect(throws: OfflineTransportError.self) {
      _ = try await firstPhone.synchronize(using: OfflineTransport())
    }
    #expect(try await firstPhone.pendingEventCount() == 1)

    // A fresh runtime and repository model process relaunch. The durable
    // outbox bytes, not in-memory task state, are the retry authority.
    let relaunchedPhone = ExperienceSyncRuntime(
      profile: profile,
      outboxStorage: outboxStorage,
      ledger: ProfileLedgerRepository(
        storage: phoneLedgerStorage,
        initialState: phoneState
      )
    )
    let transport = RuntimeTransport { data in
      try await watch.receive(data)
    }
    #expect(
      try await relaunchedPhone.synchronize(using: transport)
        == .synchronized(eventCount: 1)
    )
    #expect(try await relaunchedPhone.pendingEventCount() == 0)
    #expect(
      try await watch.currentReplay().state.derivedFacts.map(\.header.recordID) == [
        EvidenceID("offline-steps-fact")
      ])
    let returnTransport = RuntimeTransport { data in
      try await relaunchedPhone.receive(data)
    }
    #expect(try await watch.synchronize(using: returnTransport) == .idle)

    let afterAcknowledgementRelaunch = ExperienceSyncRuntime(
      profile: profile,
      outboxStorage: outboxStorage,
      ledger: ProfileLedgerRepository(
        storage: phoneLedgerStorage,
        initialState: phoneState
      )
    )
    #expect(
      try await afterAcknowledgementRelaunch.synchronize(using: transport) == .idle
    )
  }

  @Test("Duplicate delayed and reordered transfers converge to one canonical ledger")
  func duplicateDelayedAndReorderedTransfers() async throws {
    let profile = mockProfile()
    let phone = makeRuntime(profile: profile)
    let watch = makeRuntime(profile: profile)
    let first = factEnvelope(
      id: "event-a",
      evidenceID: "fact-a",
      steps: 1_000,
      profile: profile,
      revision: revision(3, origin: "phone"),
      sequence: 2
    )
    let second = factEnvelope(
      id: "event-b",
      evidenceID: "fact-b",
      steps: 2_000,
      profile: profile,
      revision: revision(2, origin: "phone"),
      sequence: 1
    )
    try await phone.runtime.recordLocal(first)
    try await phone.runtime.recordLocal(second)

    let codec = ExperienceSyncWireCodec()
    let transport = RuntimeTransport { data in
      let transfer = try codec.decodeTransfer(data)
      let reordered = ExperienceSyncTransfer(
        scope: transfer.scope,
        envelopeBytes: transfer.envelopeBytes.reversed()
      )
      let reorderedData = try codec.encode(reordered)
      let firstAcknowledgement = try await watch.runtime.receive(reorderedData)
      let repeatedAcknowledgement = try await watch.runtime.receive(reorderedData)
      #expect(firstAcknowledgement == repeatedAcknowledgement)
      return repeatedAcknowledgement
    }

    #expect(
      try await phone.runtime.synchronize(using: transport)
        == .synchronized(eventCount: 2)
    )
    let watchLedger = try await watch.ledger.currentLedger()
    let watchReplay = watchLedger.replay()
    #expect(watchLedger.envelopes.map(\.eventID) == [second.eventID, first.eventID])
    #expect(watchReplay.unresolved.isEmpty)
    #expect(
      Set(watchReplay.state.derivedFacts.map(\.header.recordID)) == [
        EvidenceID("fact-a"), EvidenceID("fact-b"),
      ])
  }

  @Test("Retry transmits the exact same envelope bytes")
  func retryUsesExactBytes() async throws {
    let profile = mockProfile()
    let phone = makeRuntime(profile: profile)
    let event = factEnvelope(
      id: "exact-retry",
      evidenceID: "exact-retry-fact",
      steps: 4_000,
      profile: profile,
      revision: revision(2, origin: "phone"),
      sequence: 1
    )
    try await phone.runtime.recordLocal(event)

    let recorder = RetryRecorder()
    let transport = RuntimeTransport { data in
      try await recorder.record(data)
    }
    for _ in 0..<2 {
      await #expect(throws: OfflineTransportError.self) {
        _ = try await phone.runtime.synchronize(using: transport)
      }
    }

    let attempts = await recorder.attempts
    #expect(attempts.count == 2)
    #expect(attempts[0] == attempts[1])
    #expect(try await phone.runtime.pendingEventCount() == 1)
  }

  @Test("Relaunch repairs a ledger event missing from the interrupted outbox")
  func ledgerFirstInterruptionRepairsOutbox() async throws {
    let profile = mockProfile()
    let event = factEnvelope(
      id: "queued-before-ledger",
      evidenceID: "queued-before-ledger-fact",
      steps: 800,
      profile: profile,
      revision: revision(2, origin: "phone"),
      sequence: 1
    )
    let phoneState = try baselineState(profile: profile)
    let phoneLedgerStorage = InMemoryProfileLedgerStorage()
    let interruptedLedger = ProfileLedgerRepository(
      storage: phoneLedgerStorage,
      initialState: phoneState
    )
    _ = try await interruptedLedger.append(event)
    let phoneLedger = ProfileLedgerRepository(
      storage: phoneLedgerStorage,
      initialState: phoneState
    )
    let phoneOutboxStorage = InMemoryExperienceSyncOutboxStorage()
    let phoneRuntime = ExperienceSyncRuntime(
      profile: profile,
      outboxStorage: phoneOutboxStorage,
      ledger: phoneLedger
    )
    let watch = makeRuntime(profile: profile)
    let transport = RuntimeTransport { data in
      try await watch.runtime.receive(data)
    }

    #expect(
      try await phoneRuntime.synchronize(using: transport)
        == .synchronized(eventCount: 1)
    )
    #expect(try await phoneRuntime.pendingEventCount() == 0)
    #expect(try await phoneLedger.currentLedger().envelopes == [event])
    #expect(try await watch.ledger.currentLedger().envelopes == [event])
  }

  @Test("Profile epoch deletion epoch and profile source mismatch fail closed")
  func scopeMismatchFailsClosed() async throws {
    let selected = mockProfile()
    let receiver = makeRuntime(profile: selected)
    let mismatches = [
      RuntimeProfile(
        id: ProfileID("other-profile"),
        epoch: selected.epoch,
        deletionEpoch: selected.deletionEpoch,
        source: selected.source
      ),
      RuntimeProfile(
        id: selected.id,
        epoch: ProfileEpoch(revision(9, origin: "selection")),
        deletionEpoch: selected.deletionEpoch,
        source: .mock(
          scenarioID: MockScenarioID("late-sleep"),
          selectionEpoch: ProfileEpoch(revision(9, origin: "selection"))
        )
      ),
      RuntimeProfile(
        id: selected.id,
        epoch: selected.epoch,
        deletionEpoch: DeletionEpoch(
          requestID: DeletionRequestID("new-delete"),
          revision: revision(7, origin: "phone")
        ),
        source: selected.source
      ),
      RuntimeProfile(
        id: selected.id,
        epoch: selected.epoch,
        deletionEpoch: selected.deletionEpoch,
        source: .mock(
          scenarioID: MockScenarioID("fast-walking"),
          selectionEpoch: selected.epoch
        )
      ),
    ]
    let codec = ExperienceSyncWireCodec()

    for (index, profile) in mismatches.enumerated() {
      let envelope = factEnvelope(
        id: "wrong-scope-\(index)",
        evidenceID: "wrong-fact-\(index)",
        steps: index,
        profile: profile,
        revision: revision(UInt64(index + 2), origin: "peer"),
        sequence: UInt64(index + 1)
      )
      let transfer = ExperienceSyncTransfer(
        scope: ExperienceSyncScope(profile: profile),
        envelopeBytes: [try ExperienceEnvelopeCodec().encode(envelope)]
      )
      await #expect(throws: ExperienceSyncRuntimeError.ledgerScopeMismatch) {
        _ = try await receiver.runtime.receive(codec.encode(transfer))
      }
    }

    #expect(try await receiver.ledger.currentLedger().envelopes.isEmpty)
  }

  @Test("A partial or forged acknowledgement never removes the outbox")
  func acknowledgementMustBeExact() async throws {
    let profile = mockProfile()
    let phone = makeRuntime(profile: profile)
    try await phone.runtime.recordLocal(
      factEnvelope(
        id: "unacknowledged",
        evidenceID: "unacknowledged-fact",
        steps: 500,
        profile: profile,
        revision: revision(2, origin: "phone"),
        sequence: 1
      )
    )
    let codec = ExperienceSyncWireCodec()
    let transport = RuntimeTransport { data in
      let transfer = try codec.decodeTransfer(data)
      return try codec.encode(
        ExperienceSyncAcknowledgement(
          scope: transfer.scope,
          eventIDs: []
        )
      )
    }

    await #expect(throws: ExperienceSyncRuntimeError.incompleteAcknowledgement) {
      _ = try await phone.runtime.synchronize(using: transport)
    }
    #expect(try await phone.runtime.pendingEventCount() == 1)
  }

  @Test("A superseded sensing event is consumed without starving newer work")
  func terminalRejectionPreservesForwardProgress() async throws {
    let profile = mockProfile()
    let oldSensingEpoch = SensingEpoch(revision(1, origin: "preference"))
    let currentSensingEpoch = SensingEpoch(revision(2, origin: "preference"))
    let sender = makeRuntime(profile: profile, sensingEpoch: oldSensingEpoch)
    let receiver = makeRuntime(profile: profile, sensingEpoch: currentSensingEpoch)
    let superseded = factEnvelope(
      id: "superseded-companion-fact",
      evidenceID: "superseded-evidence",
      steps: 100,
      profile: profile,
      revision: revision(2, origin: "watch"),
      sequence: 1,
      authorization: .companion(oldSensingEpoch)
    )
    let current = factEnvelope(
      id: "current-display-fact",
      evidenceID: "current-evidence",
      steps: 200,
      profile: profile,
      revision: revision(3, origin: "watch"),
      sequence: 2
    )
    try await sender.runtime.recordLocal(superseded)
    _ = try await sender.ledger.setCompanionSensing(
      enabled: true,
      epoch: currentSensingEpoch,
      effectiveAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    try await sender.runtime.recordLocal(current)

    let codec = ExperienceSyncWireCodec()
    let transport = RuntimeTransport { data in
      let response = try await receiver.runtime.receive(data)
      let acknowledgement = try codec.decodeAcknowledgement(response)
      #expect(acknowledgement.eventIDs == [current.eventID])
      #expect(
        acknowledgement.terminalRejections == [
          ExperienceSyncTerminalRejection(
            eventID: superseded.eventID,
            reason: .supersededSensingEpoch,
            rejectedSensingEpoch: oldSensingEpoch,
            winningSensingEpoch: currentSensingEpoch,
            companionSensingEnabled: true
          )
        ])
      return response
    }

    #expect(
      try await sender.runtime.synchronize(using: transport)
        == .synchronized(eventCount: 1)
    )
    #expect(try await sender.runtime.pendingEventCount() == 0)
    #expect(
      try await receiver.runtime.currentReplay().state.derivedFacts.map(
        \.header.recordID
      ) == [EvidenceID("current-evidence")])
  }

  @Test("A future sensing epoch retries until preference authority arrives")
  func experienceCannotOutrunPreferenceAuthority() async throws {
    let profile = mockProfile()
    let oldSensingEpoch = SensingEpoch(revision(1, origin: "preference"))
    let futureSensingEpoch = SensingEpoch(revision(2, origin: "preference"))
    let sender = makeRuntime(profile: profile, sensingEpoch: futureSensingEpoch)
    let receiver = makeRuntime(profile: profile, sensingEpoch: oldSensingEpoch)
    let event = factEnvelope(
      id: "future-authority",
      evidenceID: "future-authority-fact",
      steps: 300,
      profile: profile,
      revision: revision(2, origin: "watch"),
      sequence: 1,
      authorization: .companion(futureSensingEpoch)
    )
    try await sender.runtime.recordLocal(event)
    let transport = RuntimeTransport { data in
      try await receiver.runtime.receive(data)
    }

    await #expect(throws: (any Error).self) {
      _ = try await sender.runtime.synchronize(using: transport)
    }
    #expect(try await sender.runtime.pendingEventCount() == 1)
    #expect(try await receiver.ledger.currentLedger().envelopes.isEmpty)

    _ = try await receiver.ledger.setCompanionSensing(
      enabled: true,
      epoch: futureSensingEpoch,
      effectiveAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    #expect(
      try await sender.runtime.synchronize(using: transport)
        == .synchronized(eventCount: 1)
    )
    #expect(try await sender.runtime.pendingEventCount() == 0)
  }

  @Test("A forged sensing rejection cannot consume a coin envelope")
  func forgedTerminalRejectionCannotConsumeProductState() async throws {
    let profile = mockProfile()
    let sender = makeRuntime(profile: profile)
    let coin = coinMigrationEnvelope(profile: profile)
    try await sender.runtime.recordLocal(coin)
    let codec = ExperienceSyncWireCodec()
    let transport = RuntimeTransport { data in
      let transfer = try codec.decodeTransfer(data)
      return try codec.encode(
        ExperienceSyncAcknowledgement(
          scope: transfer.scope,
          eventIDs: [],
          terminalRejections: [
            ExperienceSyncTerminalRejection(
              eventID: coin.eventID,
              reason: .supersededSensingEpoch,
              rejectedSensingEpoch: SensingEpoch(
                revision(0, origin: "preference")
              ),
              winningSensingEpoch: SensingEpoch(
                revision(1, origin: "selection")
              ),
              companionSensingEnabled: true
            )
          ]
        )
      )
    }

    await #expect(
      throws: ExperienceSyncRuntimeError.invalidTerminalRejection(coin.eventID)
    ) {
      _ = try await sender.runtime.synchronize(using: transport)
    }
    #expect(try await sender.runtime.pendingEventCount() == 1)
  }

  @Test("Old reminder and task are consumed without blocking newer events")
  func indirectSensingDependenciesPreserveForwardProgress() async throws {
    let profile = mockProfile()
    let oldSensingEpoch = SensingEpoch(revision(1, origin: "preference"))
    let currentSensingEpoch = SensingEpoch(revision(2, origin: "preference"))
    let sender = makeRuntime(profile: profile, sensingEpoch: oldSensingEpoch)
    let receiver = makeRuntime(profile: profile, sensingEpoch: oldSensingEpoch)
    let fact = factEnvelope(
      id: "old-source-fact-envelope",
      evidenceID: "old-source-fact",
      steps: 1_000,
      profile: profile,
      revision: revision(2, origin: "watch"),
      sequence: 1,
      authorization: .companion(oldSensingEpoch)
    )
    let passive = passiveEventEnvelope(
      profile: profile,
      sensingEpoch: oldSensingEpoch
    )
    try await sender.runtime.recordLocal(fact)
    try await sender.runtime.recordLocal(passive)
    let initialTransport = RuntimeTransport { data in
      try await receiver.runtime.receive(data)
    }
    #expect(
      try await sender.runtime.synchronize(using: initialTransport)
        == .synchronized(eventCount: 2)
    )

    let reminder = reminderPresentedEnvelope(profile: profile)
    let task = taskIssuedEnvelope(profile: profile)
    try await sender.runtime.recordLocal(reminder)
    try await sender.runtime.recordLocal(task)
    _ = try await sender.ledger.setCompanionSensing(
      enabled: true,
      epoch: currentSensingEpoch,
      effectiveAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    _ = try await receiver.ledger.setCompanionSensing(
      enabled: true,
      epoch: currentSensingEpoch,
      effectiveAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let current = factEnvelope(
      id: "post-revocation-display",
      evidenceID: "post-revocation-display-fact",
      steps: 2_000,
      profile: profile,
      revision: revision(6, origin: "watch"),
      sequence: 5
    )
    try await sender.runtime.recordLocal(current)

    let codec = ExperienceSyncWireCodec()
    let transport = RuntimeTransport { data in
      let response = try await receiver.runtime.receive(data)
      let acknowledgement = try codec.decodeAcknowledgement(response)
      #expect(acknowledgement.eventIDs == [current.eventID])
      #expect(
        Set(acknowledgement.terminalRejections.map(\.eventID)) == [
          reminder.eventID, task.eventID,
        ])
      return response
    }
    #expect(
      try await sender.runtime.synchronize(using: transport)
        == .synchronized(eventCount: 1)
    )
    #expect(try await sender.runtime.pendingEventCount() == 0)
    let received = try await receiver.runtime.currentReplay().state
    #expect(received.tasks.isEmpty)
    #expect(
      received.derivedFacts.contains {
        $0.header.recordID == EvidenceID("post-revocation-display-fact")
      })
  }

  @Test("An offline old source and its dependents can be rejected in their first batch")
  func firstBatchIndirectDependenciesPreserveForwardProgress() async throws {
    let profile = mockProfile()
    let oldSensingEpoch = SensingEpoch(revision(1, origin: "preference"))
    let currentSensingEpoch = SensingEpoch(revision(2, origin: "preference"))
    let sender = makeRuntime(profile: profile, sensingEpoch: oldSensingEpoch)
    let receiver = makeRuntime(profile: profile, sensingEpoch: currentSensingEpoch)
    let fact = factEnvelope(
      id: "first-batch-old-fact-envelope",
      evidenceID: "old-source-fact",
      steps: 1_000,
      profile: profile,
      revision: revision(2, origin: "watch"),
      sequence: 1,
      authorization: .companion(oldSensingEpoch)
    )
    let passive = passiveEventEnvelope(
      profile: profile,
      sensingEpoch: oldSensingEpoch
    )
    let reminder = reminderPresentedEnvelope(profile: profile)
    let task = taskIssuedEnvelope(profile: profile)
    try await sender.runtime.recordLocal(fact)
    try await sender.runtime.recordLocal(passive)
    try await sender.runtime.recordLocal(reminder)
    try await sender.runtime.recordLocal(task)
    _ = try await sender.ledger.setCompanionSensing(
      enabled: true,
      epoch: currentSensingEpoch,
      effectiveAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let current = factEnvelope(
      id: "first-batch-current-display",
      evidenceID: "first-batch-current-fact",
      steps: 2_000,
      profile: profile,
      revision: revision(6, origin: "watch"),
      sequence: 5
    )
    try await sender.runtime.recordLocal(current)

    let codec = ExperienceSyncWireCodec()
    let transport = RuntimeTransport { data in
      let response = try await receiver.runtime.receive(data)
      let acknowledgement = try codec.decodeAcknowledgement(response)
      #expect(acknowledgement.eventIDs == [current.eventID])
      #expect(
        Set(acknowledgement.terminalRejections.map(\.eventID)) == [
          fact.eventID, passive.eventID, reminder.eventID, task.eventID,
        ])
      return response
    }
    #expect(
      try await sender.runtime.synchronize(using: transport)
        == .synchronized(eventCount: 1)
    )
    #expect(try await sender.runtime.pendingEventCount() == 0)
    let received = try await receiver.runtime.currentReplay().state
    #expect(received.passiveEvents.isEmpty)
    #expect(received.tasks.isEmpty)
    #expect(
      received.derivedFacts.map(\.header.recordID) == [
        EvidenceID("first-batch-current-fact")
      ])
  }

  @Test("Outbox serializes acknowledgement and enqueue across a suspended save")
  func outboxSerializesSuspendedWrites() async throws {
    let profile = mockProfile()
    let storage = PausingOutboxStorage()
    let outbox = ExperienceSyncOutbox(storage: storage, profile: profile)
    let first = factEnvelope(
      id: "concurrent-first",
      evidenceID: "concurrent-first-fact",
      steps: 1,
      profile: profile,
      revision: revision(2, origin: "phone"),
      sequence: 1
    )
    let second = factEnvelope(
      id: "concurrent-second",
      evidenceID: "concurrent-second-fact",
      steps: 2,
      profile: profile,
      revision: revision(3, origin: "phone"),
      sequence: 2
    )
    try await outbox.enqueue(first)
    await storage.pauseNextSave()

    let acknowledgement = Task {
      try await outbox.acknowledge(
        ExperienceSyncAcknowledgement(
          scope: ExperienceSyncScope(profile: profile),
          eventIDs: [first.eventID]
        ),
        sentEventIDs: [first.eventID]
      )
    }
    await storage.waitUntilSavePauses()
    let enqueue = Task {
      try await outbox.enqueue(second)
    }
    await storage.resumeSave()
    try await acknowledgement.value
    try await enqueue.value

    let relaunched = ExperienceSyncOutbox(storage: storage, profile: profile)
    try await relaunched.reconcile([first, second])
    let transfer = try #require(await relaunched.pendingTransfer())
    let pending = try ExperienceSyncWireCodec().decodeEnvelopes(in: transfer)
    #expect(pending.map(\.eventID) == [second.eventID])
  }

  @Test("Conversation-shaped data is rejected before it reaches the merge ledger")
  func conversationCannotEnterExperienceChannel() async throws {
    let profile = mockProfile()
    let receiver = makeRuntime(profile: profile)
    let valid = factEnvelope(
      id: "privacy-boundary",
      evidenceID: "privacy-fact",
      steps: 42,
      profile: profile,
      revision: revision(2, origin: "peer"),
      sequence: 1
    )
    let validBytes = try ExperienceEnvelopeCodec().encode(valid)
    var object = try #require(
      JSONSerialization.jsonObject(with: validBytes) as? [String: Any]
    )
    object["conversation"] = ["messages": ["private"]]
    let forbiddenBytes = try JSONSerialization.data(withJSONObject: object)
    let transfer = ExperienceSyncTransfer(
      scope: ExperienceSyncScope(profile: profile),
      envelopeBytes: [forbiddenBytes]
    )
    let rawTransfer = try CanonicalJSONCodec().encode(transfer)

    await #expect(throws: (any Error).self) {
      _ = try await receiver.runtime.receive(rawTransfer)
    }
    #expect(try await receiver.ledger.currentLedger().envelopes.isEmpty)
  }

  @Test("Wire and persisted outbox require exact canonical bounded bytes")
  func wireAndOutboxRejectNonCanonicalDocuments() async throws {
    let profile = mockProfile()
    let event = factEnvelope(
      id: "canonical-document",
      evidenceID: "canonical-document-fact",
      steps: 42,
      profile: profile,
      revision: revision(2, origin: "phone"),
      sequence: 1
    )
    let wire = ExperienceSyncWireCodec()
    let transferBytes = try wire.encode(
      ExperienceSyncTransfer(
        scope: ExperienceSyncScope(profile: profile),
        envelopeBytes: [try ExperienceEnvelopeCodec().encode(event)]
      )
    )
    #expect(throws: ExperienceSyncWireError.undeclaredField) {
      _ = try wire.decodeTransfer(Data([0x20]) + transferBytes)
    }

    let storage = InMemoryExperienceSyncOutboxStorage()
    let outbox = ExperienceSyncOutbox(
      storage: storage,
      profile: profile
    )
    try await outbox.enqueue(event)
    let canonicalDocument = try #require(await storage.load())

    let nonCanonicalStorage = InMemoryExperienceSyncOutboxStorage(
      data: Data([0x20]) + canonicalDocument
    )
    let nonCanonical = ExperienceSyncOutbox(
      storage: nonCanonicalStorage,
      profile: profile
    )
    await #expect(
      throws: ExperienceSyncOutboxError.nonCanonicalPersistedDocument
    ) {
      _ = try await nonCanonical.pendingCount()
    }

    let oversizedStorage = InMemoryExperienceSyncOutboxStorage(
      data: canonicalDocument
    )
    let oversized = ExperienceSyncOutbox(
      storage: oversizedStorage,
      profile: profile,
      maximumDocumentBytes: canonicalDocument.count - 1
    )
    await #expect(
      throws: ExperienceSyncOutboxError.oversizedPersistedDocument(
        actualBytes: canonicalDocument.count,
        maximumBytes: canonicalDocument.count - 1
      )
    ) {
      _ = try await oversized.pendingCount()
    }
  }

  @Test("Tasks coins collection memory tombstones and letters converge together")
  func comprehensiveProductFamiliesConverge() async throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRuntimeRoot =
      testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixtureURL =
      appRuntimeRoot
      .deletingLastPathComponent()
      .appendingPathComponent(
        "CompanionCore/Tests/MoriPersistenceTests/Fixtures/SchemaV1/"
          + "experience-ledger-v1-comprehensive.json"
      )
    let fixture = try ProfileLedgerCodec().decode(Data(contentsOf: fixtureURL))
    let sender = makeRuntime(initialState: fixture.initialState)
    let receiver = makeRuntime(initialState: fixture.initialState)
    for envelope in fixture.envelopes {
      try await sender.runtime.recordLocal(envelope)
    }
    let transport = RuntimeTransport { data in
      try await receiver.runtime.receive(data)
    }

    var acceptedCount = 0
    while try await sender.runtime.pendingEventCount() > 0 {
      guard
        case .synchronized(let count) =
          try await sender.runtime.synchronize(using: transport)
      else {
        Issue.record("A non-empty outbox must make forward progress")
        break
      }
      acceptedCount += count
    }

    let receivedLedger = try await receiver.ledger.currentLedger()
    #expect(acceptedCount == fixture.envelopes.count)
    #expect(receivedLedger.envelopes == fixture.envelopes)
    #expect(receivedLedger.replay() == fixture.replay())
    #expect(
      Set(receivedLedger.envelopes.map(\.eventType)).isSuperset(of: [
        .taskCompleted,
        .coinEarned,
        .cosmeticPurchased,
        .cosmeticEquipped,
        .memoryDeleted,
        .letterDelivered,
        .letterRead,
        .letterDeleted,
      ]))
  }

  #if DEBUG
    @Test("Lifecycle and connectivity automatically retry the runnable Mock pair")
    func automaticMockLifecycleRetry() async throws {
      let profile = mockProfile()
      let phone = makeRuntime(profile: profile)
      let watch = makeRuntime(profile: profile)
      let link = DeterministicMockPairedExperienceSyncLink()
      await link.attach(phone.runtime, as: .iPhone)
      await link.attach(watch.runtime, as: .watch)
      let coordinator = AutomaticExperienceSyncCoordinator(
        runtime: phone.runtime,
        transportProvider: DeterministicMockExperienceSyncTransportProvider(
          link: link,
          endpoint: .iPhone
        )
      )
      let event = factEnvelope(
        id: "automatic-lifecycle",
        evidenceID: "automatic-lifecycle-fact",
        steps: 3_250,
        profile: profile,
        revision: revision(2, origin: "phone"),
        sequence: 1
      )
      try await phone.runtime.recordLocal(event)

      await link.setReachable(false)
      await coordinator.applicationDidEnterForeground()
      #expect(try await phone.runtime.pendingEventCount() == 1)
      #expect(
        await coordinator.status()
          == AutomaticExperienceSyncStatus(
            isSynchronizing: false,
            hasPendingRetry: true,
            completedTransferCount: 0,
            acceptedEventCount: 0,
            failureCount: 1,
            coalescedTriggerCount: 0,
            lastTrigger: .applicationForeground
          )
      )

      await link.setReachable(true)
      await coordinator.connectivityDidBecomeReachable()
      #expect(try await phone.runtime.pendingEventCount() == 0)
      #expect(
        try await watch.runtime.currentReplay().state.derivedFacts.map(
          \.header.recordID
        ) == [EvidenceID("automatic-lifecycle-fact")])
      let recovered = await coordinator.status()
      #expect(recovered.hasPendingRetry == false)
      #expect(recovered.completedTransferCount == 1)
      #expect(recovered.acceptedEventCount == 1)
      #expect(recovered.failureCount == 1)
      #expect(recovered.lastTrigger == .connectivityReachable)
    }

    @Test("Concurrent lifecycle signals coalesce behind one in-flight exchange")
    func automaticTriggersCoalesce() async throws {
      let profile = mockProfile()
      let phone = makeRuntime(profile: profile)
      let watch = makeRuntime(profile: profile)
      let link = DeterministicMockPairedExperienceSyncLink()
      await link.attach(phone.runtime, as: .iPhone)
      await link.attach(watch.runtime, as: .watch)
      let coordinator = AutomaticExperienceSyncCoordinator(
        runtime: phone.runtime,
        transportProvider: DeterministicMockExperienceSyncTransportProvider(
          link: link,
          endpoint: .iPhone
        )
      )
      try await phone.runtime.recordLocal(
        factEnvelope(
          id: "coalesced-lifecycle",
          evidenceID: "coalesced-lifecycle-fact",
          steps: 500,
          profile: profile,
          revision: revision(2, origin: "phone"),
          sequence: 1
        )
      )
      await link.pauseNextExchange()

      let foreground = Task {
        await coordinator.applicationDidEnterForeground()
      }
      await link.waitUntilExchangePauses()
      async let connectivity: Void = coordinator.connectivityDidBecomeReachable()
      async let background: Void = coordinator.performBackgroundRefresh()
      _ = await (connectivity, background)
      let inFlight = await coordinator.status()
      #expect(inFlight.isSynchronizing)
      #expect(inFlight.coalescedTriggerCount == 2)

      await link.resumeExchange()
      await foreground.value
      let completed = await coordinator.status()
      #expect(completed.isSynchronizing == false)
      #expect(completed.hasPendingRetry == false)
      #expect(completed.completedTransferCount == 1)
      #expect(completed.acceptedEventCount == 1)
      #expect(completed.coalescedTriggerCount == 2)
      #expect(await link.completedExchangeCount() == 1)
      #expect(try await phone.runtime.pendingEventCount() == 0)
    }
  #endif

  @Test("A reachable signal during failure earns one coalesced retry")
  func triggerDuringFailureRetriesOnce() async throws {
    let profile = mockProfile()
    let phone = makeRuntime(profile: profile)
    let watch = makeRuntime(profile: profile)
    let transport = FailFirstAfterPauseTransport { data in
      try await watch.runtime.receive(data)
    }
    let coordinator = AutomaticExperienceSyncCoordinator(
      runtime: phone.runtime,
      transportProvider: FixedExperienceSyncTransportProvider(transport)
    )
    try await phone.runtime.recordLocal(
      factEnvelope(
        id: "retry-during-failure",
        evidenceID: "retry-during-failure-fact",
        steps: 750,
        profile: profile,
        revision: revision(2, origin: "phone"),
        sequence: 1
      )
    )

    let foreground = Task {
      await coordinator.applicationDidEnterForeground()
    }
    await transport.waitUntilFirstAttemptPauses()
    await coordinator.connectivityDidBecomeReachable()
    await transport.resumeFirstAttempt()
    await foreground.value

    #expect(await transport.attemptCount == 2)
    #expect(try await phone.runtime.pendingEventCount() == 0)
    #expect(
      try await watch.runtime.currentReplay().state.derivedFacts.map(
        \.header.recordID
      ) == [EvidenceID("retry-during-failure-fact")])
    let status = await coordinator.status()
    #expect(status.failureCount == 1)
    #expect(status.completedTransferCount == 1)
    #expect(status.coalescedTriggerCount == 1)
    #expect(status.hasPendingRetry == false)
  }
}

private struct RuntimeFixture {
  let runtime:
    ExperienceSyncRuntime<
      InMemoryExperienceSyncOutboxStorage,
      ProfileLedgerRepository<InMemoryProfileLedgerStorage>
    >
  let ledger: ProfileLedgerRepository<InMemoryProfileLedgerStorage>
}

private func makeRuntime(
  profile: RuntimeProfile,
  outboxStorage: InMemoryExperienceSyncOutboxStorage = InMemoryExperienceSyncOutboxStorage(),
  sensingEpoch: SensingEpoch = SensingEpoch(revision(1, origin: "selection"))
) -> RuntimeFixture {
  let state = try! baselineState(
    profile: profile,
    sensingEpoch: sensingEpoch
  )
  let ledger = ProfileLedgerRepository(
    storage: InMemoryProfileLedgerStorage(),
    initialState: state
  )
  return RuntimeFixture(
    runtime: ExperienceSyncRuntime(
      profile: profile,
      outboxStorage: outboxStorage,
      ledger: ledger
    ),
    ledger: ledger
  )
}

private func makeRuntime(initialState: ProfileState) -> RuntimeFixture {
  let ledger = ProfileLedgerRepository(
    storage: InMemoryProfileLedgerStorage(),
    initialState: initialState
  )
  return RuntimeFixture(
    runtime: ExperienceSyncRuntime(
      profile: initialState.runtimeProfile,
      outboxStorage: InMemoryExperienceSyncOutboxStorage(),
      ledger: ledger
    ),
    ledger: ledger
  )
}

private struct RuntimeTransport: ExperienceSyncTransport {
  let handler: @Sendable (Data) async throws -> Data

  init(handler: @escaping @Sendable (Data) async throws -> Data) {
    self.handler = handler
  }

  func exchange(_ transferData: Data) async throws -> Data {
    try await handler(transferData)
  }
}

private enum OfflineTransportError: Error {
  case unavailable
}

private struct OfflineTransport: ExperienceSyncTransport {
  func exchange(_: Data) async throws -> Data {
    throw OfflineTransportError.unavailable
  }
}

private actor RetryRecorder {
  private(set) var attempts: [Data] = []

  func record(_ data: Data) throws -> Data {
    attempts.append(data)
    throw OfflineTransportError.unavailable
  }
}

private actor PausingOutboxStorage: ExperienceSyncOutboxStorage {
  private var data: Data?
  private var shouldPauseNextSave = false
  private var saveIsPaused = false
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var saveContinuation: CheckedContinuation<Void, Never>?

  func load() -> Data? {
    data
  }

  func save(_ newData: Data) async {
    if shouldPauseNextSave {
      shouldPauseNextSave = false
      saveIsPaused = true
      let waiters = pauseWaiters
      pauseWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        saveContinuation = continuation
      }
      saveIsPaused = false
    }
    data = newData
  }

  func pauseNextSave() {
    shouldPauseNextSave = true
  }

  func waitUntilSavePauses() async {
    guard saveIsPaused == false else { return }
    await withCheckedContinuation { continuation in
      pauseWaiters.append(continuation)
    }
  }

  func resumeSave() {
    saveContinuation?.resume()
    saveContinuation = nil
  }
}

private actor FailFirstAfterPauseTransport: ExperienceSyncTransport {
  private let receiver: @Sendable (Data) async throws -> Data
  private var firstAttemptIsPaused = false
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstAttemptContinuation: CheckedContinuation<Void, Never>?
  private(set) var attemptCount = 0

  init(receiver: @escaping @Sendable (Data) async throws -> Data) {
    self.receiver = receiver
  }

  func exchange(_ transferData: Data) async throws -> Data {
    attemptCount += 1
    if attemptCount == 1 {
      firstAttemptIsPaused = true
      let waiters = pauseWaiters
      pauseWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        firstAttemptContinuation = continuation
      }
      firstAttemptIsPaused = false
      throw FailFirstTransportError.firstAttempt
    }
    return try await receiver(transferData)
  }

  func waitUntilFirstAttemptPauses() async {
    guard firstAttemptIsPaused == false else { return }
    await withCheckedContinuation { continuation in
      pauseWaiters.append(continuation)
    }
  }

  func resumeFirstAttempt() {
    firstAttemptContinuation?.resume()
    firstAttemptContinuation = nil
  }
}

private enum FailFirstTransportError: Error {
  case firstAttempt
}

private func mockProfile() -> RuntimeProfile {
  let selectionEpoch = ProfileEpoch(revision(1, origin: "selection"))
  return RuntimeProfile(
    id: ProfileID("mock-normal-day"),
    epoch: selectionEpoch,
    deletionEpoch: DeletionEpoch(
      requestID: DeletionRequestID("mock-baseline"),
      revision: revision(1, origin: "selection")
    ),
    source: .mock(
      scenarioID: MockScenarioID("normal-day"),
      selectionEpoch: selectionEpoch
    )
  )
}

private func baselineState(
  profile: RuntimeProfile,
  sensingEpoch: SensingEpoch = SensingEpoch(revision(1, origin: "selection"))
) throws -> ProfileState {
  let state = ProfileState(
    header: header(ProfileID(profile.id.rawValue), profile: profile),
    runtimeProfile: profile,
    companionSensingEnabled: true,
    currentSensingEpoch: sensingEpoch,
    selectedIdentity: .penguin,
    identityRevision: revision(1, origin: "selection"),
    coinLedger: CoinLedger(
      header: header(CoinLedgerID("coins"), profile: profile)
    ),
    collection: CollectionState(
      header: header(CollectionID("collection"), profile: profile)
    )
  )
  if let rejection = state.validate() {
    throw rejection
  }
  return state
}

private func factEnvelope(
  id: String,
  evidenceID: String,
  steps: Int,
  profile: RuntimeProfile,
  revision: LamportRevision,
  sequence: UInt64,
  authorization: EvidenceAuthorization = .displayOnly
) -> ExperienceSyncEnvelope {
  let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
  let fact = DerivedFactRecord(
    header: header(EvidenceID(evidenceID), profile: profile),
    observedAt: observedAt,
    freshUntil: observedAt.addingTimeInterval(3_600),
    value: .stepTotal(steps),
    provenance: .deterministicMock,
    authorization: authorization
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

private func coinMigrationEnvelope(
  profile: RuntimeProfile
) -> ExperienceSyncEnvelope {
  let authoredAt = Date(timeIntervalSince1970: 1_700_000_000)
  let eventRevision = revision(2, origin: "phone")
  let transaction = CoinTransaction(
    header: header(CoinTransactionID("migration-marker"), profile: profile),
    revision: eventRevision,
    authoredAt: authoredAt,
    direction: .neutral,
    amount: 0,
    reason: .migration(schemaVersion: 1)
  )
  return ExperienceSyncEnvelope(
    eventID: ExperienceEventID("coin-migration-marker"),
    eventType: .coinMigrationMarker,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    profileSource: profile.source,
    originDeviceID: eventRevision.originDeviceID,
    originSequence: 1,
    revision: eventRevision,
    observedAt: nil,
    authoredAt: authoredAt,
    privacyClass: .productState,
    tombstone: nil,
    sourceEventID: nil,
    settlementID: nil,
    payload: .coinTransaction(transaction)
  )
}

private func passiveEventEnvelope(
  profile: RuntimeProfile,
  sensingEpoch: SensingEpoch
) -> ExperienceSyncEnvelope {
  let observedAt = Date(timeIntervalSince1970: 1_700_000_010)
  let eventRevision = revision(3, origin: "watch")
  let event = PassiveCompanionEvent(
    header: header(EventID("old-walk"), profile: profile),
    sensingEpoch: sensingEpoch,
    kind: .sharedWalk,
    observedAt: observedAt,
    confidence: .high,
    evidence: [
      EvidenceReference(
        id: EvidenceID("old-source-fact"),
        kind: .stepSummary
      )
    ],
    presentationDeadline: observedAt.addingTimeInterval(120),
    replacementKey: "movement",
    taskCooldownKey: TaskCooldownKey("walk"),
    memoryEligibility: .eligible,
    sceneID: "walk",
    moriActionID: "walk",
    reminderRevision: eventRevision
  )
  return ExperienceSyncEnvelope(
    eventID: ExperienceEventID("old-walk-envelope"),
    eventType: .passiveEvent,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    profileSource: profile.source,
    originDeviceID: eventRevision.originDeviceID,
    originSequence: 2,
    revision: eventRevision,
    observedAt: observedAt,
    authoredAt: observedAt,
    privacyClass: .approvedDerived,
    tombstone: nil,
    sourceEventID: nil,
    settlementID: nil,
    payload: .passiveEvent(event)
  )
}

private func reminderPresentedEnvelope(
  profile: RuntimeProfile
) -> ExperienceSyncEnvelope {
  let authoredAt = Date(timeIntervalSince1970: 1_700_000_020)
  let eventRevision = revision(4, origin: "watch")
  let transition = PassiveEventTransition(
    header: header(EventTransitionID("old-walk-presented"), profile: profile),
    eventID: EventID("old-walk"),
    revision: eventRevision,
    state: .presented(at: authoredAt)
  )
  return ExperienceSyncEnvelope(
    eventID: ExperienceEventID("old-walk-presented-envelope"),
    eventType: .reminderPresented,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    profileSource: profile.source,
    originDeviceID: eventRevision.originDeviceID,
    originSequence: 3,
    revision: eventRevision,
    observedAt: authoredAt,
    authoredAt: authoredAt,
    privacyClass: .productState,
    tombstone: nil,
    sourceEventID: nil,
    settlementID: nil,
    payload: .passiveEventTransition(transition)
  )
}

private func taskIssuedEnvelope(
  profile: RuntimeProfile
) -> ExperienceSyncEnvelope {
  let authoredAt = Date(timeIntervalSince1970: 1_700_000_030)
  let eventRevision = revision(5, origin: "watch")
  let settlementID = TaskSettlementID("old-walk-settlement")
  let task = TaskInstance(
    header: header(TaskID("old-walk-task"), profile: profile),
    sourceEventID: EventID("old-walk"),
    kind: .walkTogether,
    cooldownKey: TaskCooldownKey("walk"),
    recommendationPriority: .recommended,
    completionPolicy: .automatic,
    issuedAt: authoredAt,
    issuedRevision: eventRevision,
    cooldownDuration: 3_600,
    expiresAt: authoredAt.addingTimeInterval(3_600),
    rewardTier: .smallest,
    settlementID: settlementID,
    lifecycleRevision: eventRevision
  )
  return ExperienceSyncEnvelope(
    eventID: ExperienceEventID("old-walk-task-envelope"),
    eventType: .taskIssued,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    profileSource: profile.source,
    originDeviceID: eventRevision.originDeviceID,
    originSequence: 4,
    revision: eventRevision,
    observedAt: authoredAt,
    authoredAt: authoredAt,
    privacyClass: .productState,
    tombstone: nil,
    sourceEventID: EventID("old-walk"),
    settlementID: settlementID,
    payload: .task(task)
  )
}

private func header<ID: Hashable & Codable & Sendable>(
  _ id: ID,
  profile: RuntimeProfile
) -> ProfileScopedRecordHeader<ID> {
  ProfileScopedRecordHeader(
    recordID: id,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch
  )
}

private func revision(_ counter: UInt64, origin: String) -> LamportRevision {
  LamportRevision(counter: counter, originDeviceID: origin)
}
