import Foundation
import MoriDomain
import MoriPersistence
import MoriRuntime
import Testing

@Suite("G8 cross-device product-loop harness")
struct ProductLoopHarnessTests {
  @Test("The comprehensive ledger converges through real file-backed runtimes")
  func comprehensiveLedgerConverges() async throws {
    let fixture = try loadComprehensiveLedger()
    let root = temporaryDirectory(named: "comprehensive")
    defer { try? FileManager.default.removeItem(at: root) }
    let phone = makeEndpoint(
      root: root,
      name: "phone",
      initialState: fixture.initialState
    )
    let watch = makeEndpoint(
      root: root,
      name: "watch",
      initialState: fixture.initialState
    )

    for envelope in fixture.envelopes {
      try await phone.runtime.recordLocal(envelope)
    }
    let transport = G8ClosureTransport { data in
      try await watch.runtime.receive(data)
    }
    let accepted = try await drain(phone.runtime, using: transport)

    let phoneLedger = try await phone.ledger.currentLedger()
    let watchLedger = try await watch.ledger.currentLedger()
    let phoneProjection = ProductLoopProjection(ledger: phoneLedger)
    let watchProjection = ProductLoopProjection(ledger: watchLedger)

    #expect(accepted == fixture.envelopes.count)
    #expect(phoneLedger == fixture)
    #expect(watchLedger == fixture)
    #expect(phoneProjection == watchProjection)
    #expect(try phoneProjection.stateDigest() == watchProjection.stateDigest())
    try assertExpectedManifest(phoneProjection, includesWatchFact: false)
  }

  @Test(
    "Independent peers converge after bidirectional faults",
    arguments: [
      UInt64(0x4D4F_5249_4738_2026),
      UInt64(0x2026_4738_4D4F_5249),
      UInt64(0xA55A_C33C_5AA5_3CC3),
    ]
  )
  func faultedDeliveryConvergesAfterRelaunch(seed: UInt64) async throws {
    let fixture = try loadComprehensiveLedger()
    let root = temporaryDirectory(named: "faulted-\(seed)")
    defer { try? FileManager.default.removeItem(at: root) }
    let firstPhone = makeEndpoint(
      root: root,
      name: "phone",
      initialState: fixture.initialState
    )
    let firstWatch = makeEndpoint(
      root: root,
      name: "watch",
      initialState: fixture.initialState
    )

    // Each endpoint independently appends a disjoint causal shard through the
    // production recordLocal path. Missing dependencies remain unresolved
    // until the opposite shard arrives. Watch also authors a Watch-attributed
    // fact that is absent from the shared fixture.
    for (index, envelope) in fixture.envelopes.enumerated() {
      if index.isMultiple(of: 2) {
        try await firstPhone.runtime.recordLocal(envelope)
      } else {
        try await firstWatch.runtime.recordLocal(envelope)
      }
    }
    try await firstWatch.runtime.recordLocal(
      makeIndependentWatchFact(profile: fixture.initialState.runtimeProfile)
    )
    let preSyncPhoneLedger = try await firstPhone.ledger.currentLedger()
    let preSyncWatchLedger = try await firstWatch.ledger.currentLedger()
    #expect(preSyncPhoneLedger.envelopes.count == 18)
    #expect(preSyncWatchLedger.envelopes.count == 18)
    #expect(
      Set(preSyncPhoneLedger.envelopes.map(\.eventID)).isDisjoint(
        with: Set(preSyncWatchLedger.envelopes.map(\.eventID))
      )
    )
    #expect(preSyncPhoneLedger.replay().unresolved.isEmpty == false)
    #expect(preSyncWatchLedger.replay().unresolved.isEmpty == false)
    await #expect(throws: G8HarnessError.offline) {
      _ = try await firstPhone.runtime.synchronize(using: G8OfflineTransport())
    }
    await #expect(throws: G8HarnessError.offline) {
      _ = try await firstWatch.runtime.synchronize(using: G8OfflineTransport())
    }
    #expect(
      try await firstPhone.runtime.pendingEventCount() == 18
    )
    #expect(try await firstWatch.runtime.pendingEventCount() == 18)

    let relaunchedPhone = firstPhone.relaunched()
    let relaunchedWatch = firstWatch.relaunched()
    let phoneToWatch = SeededDuplicateReorderingTransport(
      seed: seed
    ) { data in
      try await relaunchedWatch.runtime.receive(data)
    }
    let phoneAccepted = try await drain(
      relaunchedPhone.runtime,
      using: phoneToWatch,
      limit: 5
    )
    let watchToPhone = SeededDuplicateReorderingTransport(
      seed: seed ^ 0x9E37_79B9_7F4A_7C15
    ) { data in
      try await relaunchedPhone.runtime.receive(data)
    }
    let watchAccepted = try await drain(
      relaunchedWatch.runtime,
      using: watchToPhone,
      limit: 5
    )

    #expect(phoneAccepted == 18)
    #expect(watchAccepted == 18)
    #expect(try await relaunchedPhone.runtime.pendingEventCount() == 0)
    #expect(try await relaunchedWatch.runtime.pendingEventCount() == 0)
    #expect(await phoneToWatch.exchangeCount == 4)
    #expect(await phoneToWatch.duplicateDeliveryCount == 4)
    #expect(await phoneToWatch.reorderedBatchCount == 4)
    #expect(await watchToPhone.exchangeCount == 4)
    #expect(await watchToPhone.duplicateDeliveryCount == 4)
    #expect(await watchToPhone.reorderedBatchCount == 4)

    // Recreate both repositories and runtimes from their file bytes. This
    // verifies the final comparison is not satisfied by actor-local caches.
    let finalPhone = relaunchedPhone.relaunched()
    let finalWatch = relaunchedWatch.relaunched()
    let phoneLedger = try await finalPhone.ledger.currentLedger()
    let watchLedger = try await finalWatch.ledger.currentLedger()
    let phoneProjection = ProductLoopProjection(ledger: phoneLedger)
    let watchProjection = ProductLoopProjection(ledger: watchLedger)
    let phoneDigest = try phoneProjection.stateDigest()
    let watchDigest = try watchProjection.stateDigest()

    #expect(phoneLedger.envelopes.count == 36)
    #expect(watchLedger.envelopes.count == 36)
    let watchAuthoredEnvelope = try #require(
      phoneLedger.envelopes.first {
        $0.eventID == ExperienceEventID("g8-watch-independent-fact")
      }
    )
    #expect(watchAuthoredEnvelope.originDeviceID == "watch")
    #expect(
      watchAuthoredEnvelope.revision
        == LamportRevision(counter: 37, originDeviceID: "watch")
    )
    #expect(phoneProjection == watchProjection)
    #expect(phoneDigest == watchDigest)
    #expect(phoneDigest.sha256 == expectedDualProducerDigest)
    #expect(try await finalPhone.runtime.pendingEventCount() == 0)
    #expect(try await finalWatch.runtime.pendingEventCount() == 0)
    try assertExpectedManifest(phoneProjection, includesWatchFact: true)
  }

  @Test("Projection is stable and excludes narrative health values and chat content")
  func projectionIsContentFree() throws {
    let fixture = try loadComprehensiveLedger()
    var state = fixture.replay().state
    let profile = state.runtimeProfile
    let visibleContent = "private-visible-chat-sentinel"
    let deletedContent = "private-deleted-chat-sentinel"
    let visibleRecord = ConversationRecord(
      header: scopedHeader(
        ConversationRecordID("conversation-private-visible"),
        profile: profile
      ),
      conversationID: ConversationID("conversation-private"),
      role: .user,
      content: visibleContent,
      localTime: Date(timeIntervalSince1970: 1_700_001_000),
      referencedMemoryIDs: [],
      revision: LamportRevision(counter: 100, originDeviceID: "iphone")
    )
    let deletedRecord = ConversationRecord(
      header: scopedHeader(
        ConversationRecordID("conversation-private-deleted"),
        profile: profile
      ),
      conversationID: ConversationID("conversation-private"),
      role: .mori,
      content: deletedContent,
      localTime: Date(timeIntervalSince1970: 1_700_001_001),
      referencedMemoryIDs: [],
      revision: LamportRevision(counter: 101, originDeviceID: "iphone")
    )
    let deletion = ConversationTransition(
      header: scopedHeader(
        ConversationTransitionID("conversation-private-delete-transition"),
        profile: profile
      ),
      recordID: deletedRecord.header.recordID,
      revision: LamportRevision(counter: 102, originDeviceID: "iphone"),
      deletedAt: Date(timeIntervalSince1970: 1_700_001_002)
    )

    #expect(ProfileReducer.apply(.conversation(visibleRecord), to: &state) == .applied)
    #expect(ProfileReducer.apply(.conversation(deletedRecord), to: &state) == .applied)
    #expect(
      ProfileReducer.apply(.conversationTransition(deletion), to: &state) == .applied
    )
    let projection = ProductLoopProjection(
      replay: ProfileReplayResult(state: state, unresolved: []),
      ledgerEventCount: fixture.envelopes.count
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(projection)
    let json = try #require(String(data: encoded, encoding: .utf8))

    #expect(projection.conversation.total == 2)
    #expect(projection.conversation.visible == 1)
    #expect(projection.conversation.deleted == 1)
    #expect(json.contains(visibleContent) == false)
    #expect(json.contains(deletedContent) == false)
    #expect(json.contains("conversation-private-visible") == false)
    #expect(json.contains("conversation-private-deleted") == false)
    #expect(json.contains("今天我们一起经过了一段很长的路。") == false)
    #expect(json.contains("你停下来的时候，我也坐了一会儿。") == false)
    #expect(json.contains("今天，我们一起……") == false)
    #expect(json.contains("3250") == false)
    #expect(json.contains("27000") == false)
    #expect(json.contains("walking") == false)
    #expect(json.contains("park") == false)
    #expect(try projection.stateDigest().sha256.count == 64)
  }
}

private typealias G8LedgerRepository =
  ProfileLedgerRepository<FileProfileLedgerStorage>
private typealias G8SyncRuntime =
  ExperienceSyncRuntime<FileExperienceSyncOutboxStorage, G8LedgerRepository>

/// Golden digest for the independent 36-envelope dual-producer manifest below.
/// This is intentionally not derived from the fixture at test runtime: a reducer
/// or projection regression cannot update the oracle by also producing the same
/// wrong value on both peers.
private let expectedDualProducerDigest =
  "e0f7bb5ff4b4ebdc5b634e226b6ebd461313b9e94045e27a2f16bad567ce82a3"

private struct G8Endpoint {
  let initialState: ProfileState
  let ledgerURL: URL
  let outboxURL: URL
  let ledger: G8LedgerRepository
  let runtime: G8SyncRuntime

  func relaunched() -> Self {
    makeEndpoint(
      initialState: initialState,
      ledgerURL: ledgerURL,
      outboxURL: outboxURL
    )
  }
}

private func makeEndpoint(
  root: URL,
  name: String,
  initialState: ProfileState
) -> G8Endpoint {
  makeEndpoint(
    initialState: initialState,
    ledgerURL: root.appendingPathComponent("\(name)-ledger.json"),
    outboxURL: root.appendingPathComponent("\(name)-outbox.json")
  )
}

private func makeEndpoint(
  initialState: ProfileState,
  ledgerURL: URL,
  outboxURL: URL
) -> G8Endpoint {
  let ledger = G8LedgerRepository(
    storage: FileProfileLedgerStorage(fileURL: ledgerURL),
    initialState: initialState
  )
  return G8Endpoint(
    initialState: initialState,
    ledgerURL: ledgerURL,
    outboxURL: outboxURL,
    ledger: ledger,
    runtime: G8SyncRuntime(
      profile: initialState.runtimeProfile,
      outboxStorage: FileExperienceSyncOutboxStorage(fileURL: outboxURL),
      ledger: ledger
    )
  )
}

private struct G8ClosureTransport: ExperienceSyncTransport {
  let handler: @Sendable (Data) async throws -> Data

  init(handler: @escaping @Sendable (Data) async throws -> Data) {
    self.handler = handler
  }

  func exchange(_ transferData: Data) async throws -> Data {
    try await handler(transferData)
  }
}

private struct G8OfflineTransport: ExperienceSyncTransport {
  func exchange(_: Data) async throws -> Data {
    throw G8HarnessError.offline
  }
}

private actor SeededDuplicateReorderingTransport: ExperienceSyncTransport {
  private let receiver: @Sendable (Data) async throws -> Data
  private let codec = ExperienceSyncWireCodec()
  private var generator: SplitMix64
  private(set) var exchangeCount = 0
  private(set) var duplicateDeliveryCount = 0
  private(set) var reorderedBatchCount = 0

  init(
    seed: UInt64,
    receiver: @escaping @Sendable (Data) async throws -> Data
  ) {
    generator = SplitMix64(state: seed)
    self.receiver = receiver
  }

  func exchange(_ transferData: Data) async throws -> Data {
    exchangeCount += 1
    let transfer = try codec.decodeTransfer(transferData)
    var envelopeBytes = transfer.envelopeBytes
    for upperBound in stride(
      from: envelopeBytes.count - 1,
      through: 1,
      by: -1
    ) {
      let target = Int(generator.next() % UInt64(upperBound + 1))
      envelopeBytes.swapAt(upperBound, target)
    }
    if envelopeBytes.count > 1, envelopeBytes == transfer.envelopeBytes {
      envelopeBytes.append(envelopeBytes.removeFirst())
    }
    if envelopeBytes != transfer.envelopeBytes {
      reorderedBatchCount += 1
    }
    let reordered = ExperienceSyncTransfer(
      scope: transfer.scope,
      envelopeBytes: envelopeBytes
    )
    let reorderedData = try codec.encode(reordered)
    let firstAcknowledgement = try await receiver(reorderedData)
    let duplicateAcknowledgement = try await receiver(reorderedData)
    duplicateDeliveryCount += 1
    guard firstAcknowledgement == duplicateAcknowledgement else {
      throw G8HarnessError.duplicateAcknowledgementMismatch
    }
    return duplicateAcknowledgement
  }
}

private struct SplitMix64 {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}

private enum G8HarnessError: Error, Equatable {
  case offline
  case duplicateAcknowledgementMismatch
  case stalledWithPendingEvents
}

private func drain<Transport: ExperienceSyncTransport>(
  _ runtime: G8SyncRuntime,
  using transport: Transport,
  limit: Int = 64
) async throws -> Int {
  var accepted = 0
  while try await runtime.pendingEventCount() > 0 {
    switch try await runtime.synchronize(using: transport, limit: limit) {
    case .idle:
      throw G8HarnessError.stalledWithPendingEvents
    case .synchronized(let eventCount):
      accepted += eventCount
    }
  }
  return accepted
}

private func assertExpectedManifest(
  _ projection: ProductLoopProjection,
  includesWatchFact: Bool
) throws {
  let iphoneRevision: (UInt64) -> LamportRevision = {
    LamportRevision(counter: $0, originDeviceID: "iphone")
  }
  let sensingEpoch = SensingEpoch(iphoneRevision(1))
  let expectedProfile = RuntimeProfile(
    id: ProfileID("schema-real"),
    epoch: ProfileEpoch(iphoneRevision(1)),
    deletionEpoch: DeletionEpoch(
      requestID: DeletionRequestID("schema-deletion-fence"),
      revision: iphoneRevision(1)
    ),
    source: .real
  )
  #expect(projection.profile == expectedProfile)
  #expect(projection.companionSensingEnabled)
  #expect(projection.currentSensingEpoch == sensingEpoch)
  #expect(projection.selectedIdentity == .polarBear)
  #expect(projection.identityRevision == iphoneRevision(21))
  #expect(projection.tone == .gentle)

  let expectedFactIDs =
    [
      EvidenceID("foreground"),
      EvidenceID("motion"),
      EvidenceID("place"),
      EvidenceID("sleep"),
      EvidenceID("steps"),
    ] + (includesWatchFact ? [EvidenceID("watch-local-foreground")] : [])
  #expect(projection.facts.map(\.id) == expectedFactIDs)
  #expect(
    projection.facts.map(\.kind)
      == [
        .foregroundInteraction,
        .broadMotion,
        .approvedPlaceCategory,
        .sleepDuration,
        .stepSummary,
      ] + (includesWatchFact ? [.foregroundInteraction] : [])
  )
  #expect(
    projection.facts.map(\.provenance)
      == [
        .foregroundInteraction,
        .motionClassifier,
        .coarsePlaceClassifier,
        .healthSummary,
        .healthSummary,
      ] + (includesWatchFact ? [.foregroundInteraction] : [])
  )
  #expect(
    projection.facts.map(\.authorization)
      == [
        .displayOnly,
        .displayOnly,
        .displayOnly,
        .displayOnly,
        .companion(sensingEpoch),
      ] + (includesWatchFact ? [.displayOnly] : [])
  )

  #expect(projection.events.count == 5)
  let confirmed = try #require(
    projection.events.first { $0.id == EventID("confirmed") }
  )
  #expect(confirmed.kind == .foregroundGreeting)
  #expect(confirmed.sensingEpoch == sensingEpoch)
  #expect(confirmed.confidence == .high)
  #expect(
    confirmed.evidence
      == [EvidenceReference(id: EvidenceID("steps"), kind: .stepSummary)]
  )
  #expect(confirmed.memoryEligibility == .eligible)
  #expect(confirmed.taskCooldownKey == TaskCooldownKey("confirmed"))
  #expect(confirmed.reminderLifecycle == .pending)
  #expect(confirmed.reminderRevision == iphoneRevision(33))

  let pause = try #require(projection.events.first { $0.id == EventID("pause") })
  #expect(pause.kind == .pausedTogether)
  #expect(pause.reminderLifecycle == .expired)
  #expect(pause.reminderRevision == iphoneRevision(13))

  let pace = try #require(projection.events.first { $0.id == EventID("pace") })
  #expect(pace.kind == .fastPace)
  #expect(pace.reminderLifecycle == .replaced(by: EventID("newer-pace")))
  #expect(pace.reminderRevision == iphoneRevision(15))

  let reflect = try #require(
    projection.events.first { $0.id == EventID("reflect") }
  )
  #expect(reflect.kind == .foregroundGreeting)
  #expect(reflect.reminderLifecycle == .pending)
  #expect(reflect.reminderRevision == iphoneRevision(26))

  let walk = try #require(projection.events.first { $0.id == EventID("walk") })
  #expect(walk.kind == .sharedWalk)
  #expect(walk.reminderLifecycle == .presented)
  #expect(walk.reminderRevision == iphoneRevision(4))

  #expect(projection.tasks.count == 4)
  let confirmedTask = try #require(
    projection.tasks.first { $0.id == TaskID("confirmed-task") }
  )
  #expect(confirmedTask.sourceEventID == EventID("confirmed"))
  #expect(confirmedTask.kind == .reflectOnDay)
  #expect(confirmedTask.cooldownKey == TaskCooldownKey("confirmed"))
  #expect(confirmedTask.recommendationPriority == .recommended)
  #expect(confirmedTask.completionPolicy == .userConfirmation)
  #expect(confirmedTask.rewardTier == .smallest)
  #expect(
    confirmedTask.settlementID == TaskSettlementID("settlement-confirmed-task")
  )
  #expect(confirmedTask.lifecycle == .completed(method: .userConfirmed))
  #expect(confirmedTask.issuedRevision == iphoneRevision(34))
  #expect(confirmedTask.lifecycleRevision == iphoneRevision(35))
  #expect(
    confirmedTask.winningTransitionID == TaskTransitionID("confirmed-by-user")
  )

  let pauseTask = try #require(
    projection.tasks.first { $0.id == TaskID("pause-task") }
  )
  #expect(pauseTask.sourceEventID == EventID("pause"))
  #expect(pauseTask.kind == .walkTogether)
  #expect(pauseTask.completionPolicy == .automatic)
  #expect(pauseTask.rewardTier == .standard)
  #expect(pauseTask.settlementID == TaskSettlementID("settlement-pause-task"))
  #expect(pauseTask.lifecycle == .completed(method: .automatic))
  #expect(pauseTask.issuedRevision == iphoneRevision(9))
  #expect(pauseTask.lifecycleRevision == iphoneRevision(10))
  #expect(pauseTask.winningTransitionID == TaskTransitionID("pause-completed"))

  let reflectTask = try #require(
    projection.tasks.first { $0.id == TaskID("reflect-task") }
  )
  #expect(reflectTask.sourceEventID == EventID("reflect"))
  #expect(reflectTask.kind == .reflectOnDay)
  #expect(reflectTask.completionPolicy == .userConfirmation)
  #expect(reflectTask.rewardTier == .smallest)
  #expect(reflectTask.settlementID == TaskSettlementID("settlement-reflect-task"))
  #expect(reflectTask.lifecycle == .expired)
  #expect(reflectTask.issuedRevision == iphoneRevision(27))
  #expect(reflectTask.lifecycleRevision == iphoneRevision(28))
  #expect(reflectTask.winningTransitionID == TaskTransitionID("reflect-expired"))

  let walkTask = try #require(
    projection.tasks.first { $0.id == TaskID("walk-task") }
  )
  #expect(walkTask.sourceEventID == EventID("walk"))
  #expect(walkTask.kind == .walkTogether)
  #expect(walkTask.completionPolicy == .automatic)
  #expect(walkTask.rewardTier == .rare10)
  #expect(walkTask.settlementID == TaskSettlementID("settlement-walk-task"))
  #expect(walkTask.lifecycle == .completed(method: .automatic))
  #expect(walkTask.issuedRevision == iphoneRevision(5))
  #expect(walkTask.lifecycleRevision == iphoneRevision(6))
  #expect(walkTask.winningTransitionID == TaskTransitionID("walk-completed"))

  #expect(projection.cooldowns.count == 4)
  #expect(
    projection.cooldowns.map(\.id)
      == [
        TaskCooldownID("cooldown:confirmed:confirmed-task"),
        TaskCooldownID("cooldown:pause:pause-task"),
        TaskCooldownID("cooldown:reflect:reflect-task"),
        TaskCooldownID("cooldown:walk:walk-task"),
      ]
  )
  #expect(projection.cooldowns.allSatisfy { $0.duration == 900 })
  #expect(
    projection.cooldowns.map(\.revision)
      == [
        iphoneRevision(34),
        iphoneRevision(9),
        iphoneRevision(27),
        iphoneRevision(5),
      ]
  )

  #expect(projection.coins.ledgerID == CoinLedgerID("coins"))
  #expect(projection.coins.balance == 7)
  #expect(projection.coins.transactions.count == 6)
  #expect(
    projection.coins.transactions.map(\.id)
      == [
        CoinTransactionID("confirmed-reward"),
        CoinTransactionID("migration-marker"),
        CoinTransactionID("pause-reversal"),
        CoinTransactionID("pause-reward"),
        CoinTransactionID("purchase-raincoat"),
        CoinTransactionID("walk-reward"),
      ]
  )
  #expect(
    projection.coins.transactions.map(\.direction)
      == [.credit, .neutral, .debit, .credit, .debit, .credit]
  )
  #expect(projection.coins.transactions.map(\.amount) == [1, 0, 2, 2, 4, 10])
  #expect(
    projection.coins.transactions.map(\.reason)
      == [
        .taskReward(TaskSettlementID("settlement-confirmed-task")),
        .migration(schemaVersion: 1),
        .reversal(CoinTransactionID("pause-reward")),
        .taskReward(TaskSettlementID("settlement-pause-task")),
        .cosmeticPurchase(CosmeticID("raincoat")),
        .taskReward(TaskSettlementID("settlement-walk-task")),
      ]
  )

  #expect(projection.collection.collectionID == CollectionID("collection"))
  #expect(projection.collection.ownership.count == 2)
  #expect(
    projection.collection.ownership.map(\.id)
      == [
        CollectionOwnershipID("ownership-gift"),
        CollectionOwnershipID("ownership-raincoat"),
      ]
  )
  #expect(
    projection.collection.ownership.map(\.cosmeticID)
      == [CosmeticID("gift-pin"), CosmeticID("raincoat")]
  )
  #expect(projection.collection.ownership.map(\.slot) == [.accessory, .outfit])
  #expect(
    projection.collection.ownership.map(\.purchaseTransactionID)
      == [nil, CoinTransactionID("purchase-raincoat")]
  )
  #expect(projection.collection.equipped.count == 1)
  #expect(projection.collection.equipped.first?.slot == .outfit)
  #expect(projection.collection.equipped.first?.cosmeticID == CosmeticID("raincoat"))
  #expect(projection.collection.equipped.first?.revision == iphoneRevision(24))
  #expect(
    projection.collection.equipped.first?.transitionID
      == CollectionTransitionID("equip-raincoat")
  )

  #expect(projection.memories.count == 1)
  #expect(
    projection.memories.first?.id == MemoryID("daily-562136865b39e679")
  )
  #expect(projection.memories.first?.visibility == .deleted)
  #expect(projection.memories.first?.factCount == 0)
  #expect(projection.memories.first?.authoredRevision == iphoneRevision(16))
  #expect(projection.memories.first?.deletionRevision == iphoneRevision(20))
  #expect(
    projection.memories.first?.winningTransitionID
      == MemoryTransitionID("memory-delete")
  )

  #expect(projection.letters.count == 1)
  #expect(projection.letters.first?.id == LetterID("daily-letter"))
  #expect(
    projection.letters.first?.source
      == .memory(MemoryID("daily-562136865b39e679"))
  )
  #expect(projection.letters.first?.authoredRevision == iphoneRevision(17))
  #expect(projection.letters.first?.isRead == true)
  #expect(projection.letters.first?.readRevision == iphoneRevision(18))
  #expect(
    projection.letters.first?.readTransitionID
      == LetterTransitionID("letter-read")
  )
  #expect(projection.letters.first?.isDeleted == true)
  #expect(projection.letters.first?.deletionRevision == iphoneRevision(19))
  #expect(
    projection.letters.first?.deletionTransitionID
      == LetterTransitionID("letter-delete")
  )

  #expect(projection.conversation.total == 0)
  #expect(projection.conversation.visible == 0)
  #expect(projection.conversation.deleted == 0)
  #expect(projection.unresolved.isEmpty)
  let eventCount = includesWatchFact ? 36 : 35
  #expect(projection.acceptedEventCount == eventCount)
  #expect(projection.ledgerEventCount == eventCount)
}

private func makeIndependentWatchFact(
  profile: RuntimeProfile
) -> ExperienceSyncEnvelope {
  let revision = LamportRevision(counter: 37, originDeviceID: "watch")
  let observedAt = Date(timeIntervalSince1970: 1_700_000_100)
  let fact = DerivedFactRecord(
    header: scopedHeader(
      EvidenceID("watch-local-foreground"),
      profile: profile
    ),
    observedAt: observedAt,
    freshUntil: observedAt.addingTimeInterval(60),
    value: .foregroundInteraction,
    provenance: .foregroundInteraction,
    authorization: .displayOnly
  )
  return ExperienceSyncEnvelope(
    eventID: ExperienceEventID("g8-watch-independent-fact"),
    eventType: .derivedFact,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    profileSource: profile.source,
    originDeviceID: revision.originDeviceID,
    originSequence: 1,
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

private func loadComprehensiveLedger() throws -> ProfileLedger {
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
  return try ProfileLedgerCodec().decode(Data(contentsOf: fixtureURL))
}

private func temporaryDirectory(named name: String) -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent(
      "mori-g8-\(name)-\(UUID().uuidString)",
      isDirectory: true
    )
}

private func scopedHeader<RecordID: Hashable & Codable & Sendable>(
  _ recordID: RecordID,
  profile: RuntimeProfile
) -> ProfileScopedRecordHeader<RecordID> {
  ProfileScopedRecordHeader(
    recordID: recordID,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch
  )
}
