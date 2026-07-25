import Foundation
import MoriDomain
import MoriPersistence
import Testing

@Suite("Comprehensive version-one experience schema")
struct ComprehensiveSchemaFixtureTests {
  @Test("Golden ledger freezes every synchronized payload family")
  func comprehensiveLedger() throws {
    let expected = try makeComprehensiveLedger()
    let expectedData = try ProfileLedgerCodec().encode(expected)

    let fixtureData = try canonicalComprehensiveFixture(
      "experience-ledger-v1-comprehensive"
    )
    let decoded = try ProfileLedgerCodec().decode(fixtureData)
    #expect(decoded == expected)
    #expect(expectedData == fixtureData)
    #expect(decoded.replay().unresolved.isEmpty)
    #expect(payloadCoverage(decoded.envelopes) == expectedPayloadCoverage)
    #expect(schemaShapeCoverage(decoded.envelopes) == expectedSchemaShapeCoverage)
  }

  @Test("Golden envelope freezes Mock source and deterministic provenance")
  func mockEnvelope() throws {
    let expected = makeMockSchemaEnvelope()
    let expectedData = try ExperienceEnvelopeCodec().encode(expected)
    let fixtureData = try canonicalComprehensiveFixture("experience-envelope-v1-mock")
    let decoded = try ExperienceEnvelopeCodec().decode(fixtureData)

    #expect(decoded == expected)
    #expect(expectedData == fixtureData)
    #expect(
      schemaShapeCoverage([decoded]) == [
        "fact.broadMotion.deterministicMock",
        "factAuthorization.displayOnly",
        "source.mock",
      ])
  }

  @Test("Fixed negative fixtures reject future and undeclared schema recursively")
  func negativeFixtures() throws {
    let codec = ExperienceEnvelopeCodec()
    #expect(
      throws: ExperienceEnvelopeCodecError.invalidEnvelope(.invalidSchema)
    ) {
      _ = try codec.decode(
        canonicalComprehensiveFixture("experience-envelope-future-schema")
      )
    }
    #expect(
      throws: ExperienceEnvelopeCodecError.undeclaredField(
        "$.unexpectedDisplayHint"
      )
    ) {
      _ = try codec.decode(
        canonicalComprehensiveFixture("experience-envelope-unknown-field")
      )
    }
    #expect(
      throws: ExperienceEnvelopeCodecError.undeclaredField(
        "$.payload.derivedFact._0.value.unexpectedClassifierHint"
      )
    ) {
      _ = try codec.decode(
        canonicalComprehensiveFixture("experience-envelope-unknown-nested-field")
      )
    }
  }
}

private let comprehensiveNow = Date(timeIntervalSince1970: 1_700_000_000)

private func comprehensiveRevision(_ counter: UInt64) -> LamportRevision {
  LamportRevision(counter: counter, originDeviceID: "iphone")
}

private func comprehensiveHeader<ID>(
  _ id: ID,
  profile: RuntimeProfile
) -> ProfileScopedRecordHeader<ID> where ID: Hashable & Codable & Sendable {
  ProfileScopedRecordHeader(
    recordID: id,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch
  )
}

private func makeComprehensiveLedger() throws -> ProfileLedger {
  let profile = RuntimeProfile(
    id: ProfileID("schema-real"),
    epoch: ProfileEpoch(comprehensiveRevision(1)),
    deletionEpoch: DeletionEpoch(
      requestID: DeletionRequestID("schema-deletion-fence"),
      revision: comprehensiveRevision(1)
    ),
    source: .real
  )
  let sensingEpoch = SensingEpoch(comprehensiveRevision(1))
  let initialState = ProfileState(
    header: comprehensiveHeader(profile.id, profile: profile),
    runtimeProfile: profile,
    companionSensingEnabled: true,
    currentSensingEpoch: sensingEpoch,
    selectedIdentity: .penguin,
    identityRevision: comprehensiveRevision(1),
    coinLedger: CoinLedger(
      header: comprehensiveHeader(CoinLedgerID("coins"), profile: profile)
    ),
    collection: CollectionState(
      header: comprehensiveHeader(CollectionID("collection"), profile: profile)
    )
  )

  let fact = DerivedFactRecord(
    header: comprehensiveHeader(EvidenceID("steps"), profile: profile),
    observedAt: comprehensiveNow,
    freshUntil: comprehensiveNow.addingTimeInterval(3_600),
    value: .stepTotal(3_250),
    provenance: .healthSummary,
    authorization: .companion(sensingEpoch)
  )
  let sleepFact = DerivedFactRecord(
    header: comprehensiveHeader(EvidenceID("sleep"), profile: profile),
    observedAt: comprehensiveNow,
    freshUntil: comprehensiveNow.addingTimeInterval(3_600),
    value: .sleepDuration(27_000),
    provenance: .healthSummary
  )
  let motionFact = DerivedFactRecord(
    header: comprehensiveHeader(EvidenceID("motion"), profile: profile),
    observedAt: comprehensiveNow,
    freshUntil: comprehensiveNow.addingTimeInterval(3_600),
    value: .broadMotion(.walking),
    provenance: .motionClassifier
  )
  let placeFact = DerivedFactRecord(
    header: comprehensiveHeader(EvidenceID("place"), profile: profile),
    observedAt: comprehensiveNow,
    freshUntil: comprehensiveNow.addingTimeInterval(3_600),
    value: .approvedPlaceCategory(.park),
    provenance: .coarsePlaceClassifier
  )
  let foregroundFact = DerivedFactRecord(
    header: comprehensiveHeader(EvidenceID("foreground"), profile: profile),
    observedAt: comprehensiveNow,
    freshUntil: comprehensiveNow.addingTimeInterval(3_600),
    value: .foregroundInteraction,
    provenance: .foregroundInteraction
  )
  let walk = comprehensiveEvent(
    "walk",
    profile: profile,
    sensingEpoch: sensingEpoch,
    kind: .sharedWalk,
    observedOffset: 10,
    cooldownKey: "walk",
    revision: 3
  )
  let walkPresented = PassiveEventTransition(
    header: comprehensiveHeader(
      EventTransitionID("walk-presented"),
      profile: profile
    ),
    eventID: walk.header.recordID,
    revision: comprehensiveRevision(4),
    state: .presented(at: comprehensiveNow.addingTimeInterval(12))
  )
  let walkTask = comprehensiveTask(
    "walk-task",
    event: walk,
    profile: profile,
    revision: 5,
    reward: .rare10
  )
  let walkCompleted = comprehensiveCompletion(
    "walk-completed",
    task: walkTask,
    profile: profile,
    revision: 6
  )
  let walkReward = CoinTransaction(
    header: comprehensiveHeader(CoinTransactionID("walk-reward"), profile: profile),
    revision: comprehensiveRevision(7),
    authoredAt: comprehensiveNow.addingTimeInterval(17),
    direction: .credit,
    amount: CoinRewardTier.rare10.rawValue,
    reason: .taskReward(walkTask.settlementID)
  )

  let pause = comprehensiveEvent(
    "pause",
    profile: profile,
    sensingEpoch: sensingEpoch,
    kind: .pausedTogether,
    observedOffset: 20,
    cooldownKey: "pause",
    revision: 8
  )
  let pauseTask = comprehensiveTask(
    "pause-task",
    event: pause,
    profile: profile,
    revision: 9,
    reward: .standard
  )
  let pauseCompleted = comprehensiveCompletion(
    "pause-completed",
    task: pauseTask,
    profile: profile,
    revision: 10
  )
  let pauseReward = CoinTransaction(
    header: comprehensiveHeader(CoinTransactionID("pause-reward"), profile: profile),
    revision: comprehensiveRevision(11),
    authoredAt: comprehensiveNow.addingTimeInterval(27),
    direction: .credit,
    amount: CoinRewardTier.standard.rawValue,
    reason: .taskReward(pauseTask.settlementID)
  )
  let rewardReversal = CoinTransaction(
    header: comprehensiveHeader(CoinTransactionID("pause-reversal"), profile: profile),
    revision: comprehensiveRevision(12),
    authoredAt: comprehensiveNow.addingTimeInterval(28),
    direction: .debit,
    amount: CoinRewardTier.standard.rawValue,
    reason: .reversal(pauseReward.header.recordID)
  )
  let pauseExpired = PassiveEventTransition(
    header: comprehensiveHeader(
      EventTransitionID("pause-expired"),
      profile: profile
    ),
    eventID: pause.header.recordID,
    revision: comprehensiveRevision(13),
    state: .expired(at: comprehensiveNow.addingTimeInterval(29))
  )

  let pace = comprehensiveEvent(
    "pace",
    profile: profile,
    sensingEpoch: sensingEpoch,
    kind: .fastPace,
    observedOffset: 30,
    cooldownKey: "pace",
    revision: 14
  )
  let paceReplaced = PassiveEventTransition(
    header: comprehensiveHeader(
      EventTransitionID("pace-replaced"),
      profile: profile
    ),
    eventID: pace.header.recordID,
    revision: comprehensiveRevision(15),
    state: .replaced(
      by: EventID("newer-pace"),
      at: comprehensiveNow.addingTimeInterval(32)
    )
  )

  let localDay = LocalDay("2023-11-14")
  let memoryID = MemoryID.daily(
    profileID: profile.id,
    profileEpoch: profile.epoch,
    localDay: localDay,
    timeZoneIdentifier: "UTC"
  )
  let memory = MemoryRecord(
    header: comprehensiveHeader(memoryID, profile: profile),
    localDay: localDay,
    timeZoneIdentifier: "UTC",
    authoredRevision: comprehensiveRevision(16),
    lifecycle: .sealed(
      SealedMemoryContent(
        facts: [
          MemoryFactReference(
            evidenceID: fact.header.recordID,
            kind: .stepSummary,
            sourceEventID: walk.header.recordID
          )
        ],
        narrative: "今天我们一起经过了一段很长的路。",
        sceneID: "spring-valley",
        moriActionID: "rest.sit",
        sealedAt: comprehensiveNow.addingTimeInterval(40)
      )
    )
  )
  let letter = LetterRecord(
    header: comprehensiveHeader(LetterID("daily-letter"), profile: profile),
    source: .memory(memoryID),
    title: "今天，我们一起……",
    body: "你停下来的时候，我也坐了一会儿。",
    deliveredAt: comprehensiveNow.addingTimeInterval(41),
    authoredRevision: comprehensiveRevision(17)
  )
  let letterRead = LetterTransition(
    header: comprehensiveHeader(
      LetterTransitionID("letter-read"),
      profile: profile
    ),
    letterID: letter.header.recordID,
    revision: comprehensiveRevision(18),
    kind: .read(at: comprehensiveNow.addingTimeInterval(42))
  )
  let letterDelete = LetterTransition(
    header: comprehensiveHeader(
      LetterTransitionID("letter-delete"),
      profile: profile
    ),
    letterID: letter.header.recordID,
    revision: comprehensiveRevision(19),
    kind: .delete(at: comprehensiveNow.addingTimeInterval(43))
  )
  let memoryDelete = MemoryTransition(
    header: comprehensiveHeader(
      MemoryTransitionID("memory-delete"),
      profile: profile
    ),
    memoryID: memoryID,
    revision: comprehensiveRevision(20),
    kind: .delete(at: comprehensiveNow.addingTimeInterval(44))
  )
  let identity = IdentitySelectionRecord(
    header: comprehensiveHeader(
      IdentitySelectionID("identity-selection"),
      profile: profile
    ),
    identity: .polarBear,
    revision: comprehensiveRevision(21)
  )

  let raincoat = CosmeticCatalogItem(
    id: CosmeticID("raincoat"),
    slot: .outfit,
    coinPrice: 4
  )
  let purchaseTransaction = CoinTransaction(
    header: comprehensiveHeader(
      CoinTransactionID("purchase-raincoat"),
      profile: profile
    ),
    revision: comprehensiveRevision(22),
    authoredAt: comprehensiveNow.addingTimeInterval(46),
    direction: .debit,
    amount: raincoat.coinPrice,
    reason: .cosmeticPurchase(raincoat.id)
  )
  let purchaseOwnership = CollectionOwnershipRecord(
    header: comprehensiveHeader(
      CollectionOwnershipID("ownership-raincoat"),
      profile: profile
    ),
    cosmeticID: raincoat.id,
    slot: raincoat.slot,
    acquiredAt: comprehensiveNow.addingTimeInterval(46),
    purchaseTransactionID: purchaseTransaction.header.recordID,
    revision: comprehensiveRevision(22)
  )
  let purchase = CollectionPurchaseRecord(
    item: raincoat,
    ownership: purchaseOwnership,
    transaction: purchaseTransaction
  )
  let giftedAccessory = CollectionOwnershipRecord(
    header: comprehensiveHeader(
      CollectionOwnershipID("ownership-gift"),
      profile: profile
    ),
    cosmeticID: CosmeticID("gift-pin"),
    slot: .accessory,
    acquiredAt: comprehensiveNow.addingTimeInterval(47),
    purchaseTransactionID: nil,
    revision: comprehensiveRevision(23)
  )
  let equip = CollectionTransition(
    header: comprehensiveHeader(
      CollectionTransitionID("equip-raincoat"),
      profile: profile
    ),
    cosmeticID: raincoat.id,
    slot: raincoat.slot,
    revision: comprehensiveRevision(24)
  )
  let migrationMarker = CoinTransaction(
    header: comprehensiveHeader(
      CoinTransactionID("migration-marker"),
      profile: profile
    ),
    revision: comprehensiveRevision(25),
    authoredAt: comprehensiveNow.addingTimeInterval(49),
    direction: .neutral,
    amount: 0,
    reason: .migration(schemaVersion: 1)
  )

  let reflect = comprehensiveEvent(
    "reflect",
    profile: profile,
    sensingEpoch: sensingEpoch,
    kind: .foregroundGreeting,
    observedOffset: 50,
    cooldownKey: "reflect",
    revision: 26
  )
  let reflectTask = comprehensiveTask(
    "reflect-task",
    event: reflect,
    profile: profile,
    revision: 27,
    reward: .smallest,
    completionPolicy: .userConfirmation,
    expiresOffset: 55
  )
  let reflectExpired = TaskTransition(
    header: comprehensiveHeader(
      TaskTransitionID("reflect-expired"),
      profile: profile
    ),
    taskID: reflectTask.header.recordID,
    revision: comprehensiveRevision(28),
    state: .expired(at: comprehensiveNow.addingTimeInterval(56)),
    settlementID: nil
  )
  let confirmedEvent = comprehensiveEvent(
    "confirmed",
    profile: profile,
    sensingEpoch: sensingEpoch,
    kind: .foregroundGreeting,
    observedOffset: 30,
    cooldownKey: "confirmed",
    revision: 33
  )
  let confirmedTask = comprehensiveTask(
    "confirmed-task",
    event: confirmedEvent,
    profile: profile,
    revision: 34,
    reward: .smallest,
    completionPolicy: .userConfirmation
  )
  let userConfirmed = comprehensiveCompletion(
    "confirmed-by-user",
    task: confirmedTask,
    profile: profile,
    revision: 35,
    method: .userConfirmed
  )
  let confirmedReward = CoinTransaction(
    header: comprehensiveHeader(
      CoinTransactionID("confirmed-reward"),
      profile: profile
    ),
    revision: comprehensiveRevision(36),
    authoredAt: comprehensiveNow.addingTimeInterval(36),
    direction: .credit,
    amount: CoinRewardTier.smallest.rawValue,
    reason: .taskReward(confirmedTask.settlementID)
  )

  let payloads: [ComprehensiveEnvelopeInput] = [
    .init(2, "fact", .derivedFact(fact), observedAt: fact.observedAt),
    .init(3, "walk", .passiveEvent(walk), observedAt: walk.observedAt),
    .init(4, "walk-presented", .passiveEventTransition(walkPresented)),
    .init(
      5,
      "walk-task",
      .task(walkTask),
      sourceEventID: walk.header.recordID,
      settlementID: walkTask.settlementID
    ),
    .init(
      6,
      "walk-completed",
      .taskTransition(walkCompleted),
      settlementID: walkTask.settlementID
    ),
    .init(
      7,
      "walk-reward",
      .coinTransaction(walkReward),
      settlementID: walkTask.settlementID
    ),
    .init(8, "pause", .passiveEvent(pause), observedAt: pause.observedAt),
    .init(
      9,
      "pause-task",
      .task(pauseTask),
      sourceEventID: pause.header.recordID,
      settlementID: pauseTask.settlementID
    ),
    .init(
      10,
      "pause-completed",
      .taskTransition(pauseCompleted),
      settlementID: pauseTask.settlementID
    ),
    .init(
      11,
      "pause-reward",
      .coinTransaction(pauseReward),
      settlementID: pauseTask.settlementID
    ),
    .init(12, "pause-reversal", .coinTransaction(rewardReversal)),
    .init(13, "pause-expired", .passiveEventTransition(pauseExpired)),
    .init(14, "pace", .passiveEvent(pace), observedAt: pace.observedAt),
    .init(15, "pace-replaced", .passiveEventTransition(paceReplaced)),
    .init(16, "memory", .memory(memory)),
    .init(17, "letter", .letter(letter)),
    .init(18, "letter-read", .letterTransition(letterRead)),
    .init(
      19,
      "letter-delete",
      .letterTransition(letterDelete),
      tombstoneTarget: letter.header.recordID.rawValue
    ),
    .init(
      20,
      "memory-delete",
      .memoryTransition(memoryDelete),
      tombstoneTarget: memoryID.rawValue
    ),
    .init(21, "identity", .identitySelection(identity)),
    .init(22, "purchase", .collectionPurchase(purchase)),
    .init(23, "gift", .collectionOwnership(giftedAccessory)),
    .init(24, "equip", .collectionTransition(equip)),
    .init(25, "migration", .coinTransaction(migrationMarker)),
    .init(26, "reflect", .passiveEvent(reflect), observedAt: reflect.observedAt),
    .init(
      27,
      "reflect-task",
      .task(reflectTask),
      sourceEventID: reflect.header.recordID,
      settlementID: reflectTask.settlementID
    ),
    .init(28, "reflect-expired", .taskTransition(reflectExpired)),
    .init(29, "sleep-fact", .derivedFact(sleepFact), observedAt: sleepFact.observedAt),
    .init(30, "motion-fact", .derivedFact(motionFact), observedAt: motionFact.observedAt),
    .init(31, "place-fact", .derivedFact(placeFact), observedAt: placeFact.observedAt),
    .init(
      32,
      "foreground-fact",
      .derivedFact(foregroundFact),
      observedAt: foregroundFact.observedAt
    ),
    .init(
      33,
      "confirmed-event",
      .passiveEvent(confirmedEvent),
      observedAt: confirmedEvent.observedAt
    ),
    .init(
      34,
      "confirmed-task",
      .task(confirmedTask),
      sourceEventID: confirmedEvent.header.recordID,
      settlementID: confirmedTask.settlementID
    ),
    .init(
      35,
      "confirmed-by-user",
      .taskTransition(userConfirmed),
      settlementID: confirmedTask.settlementID
    ),
    .init(
      36,
      "confirmed-reward",
      .coinTransaction(confirmedReward),
      settlementID: confirmedTask.settlementID
    ),
  ]
  let envelopes = payloads.map { $0.envelope(profile: profile) }
  return try ProfileLedger(initialState: initialState, envelopes: envelopes)
}

private struct ComprehensiveEnvelopeInput {
  let counter: UInt64
  let id: String
  let payload: ExperienceSyncPayload
  let observedAt: Date?
  let sourceEventID: EventID?
  let settlementID: TaskSettlementID?
  let tombstoneTarget: String?

  init(
    _ counter: UInt64,
    _ id: String,
    _ payload: ExperienceSyncPayload,
    observedAt: Date? = nil,
    sourceEventID: EventID? = nil,
    settlementID: TaskSettlementID? = nil,
    tombstoneTarget: String? = nil
  ) {
    self.counter = counter
    self.id = id
    self.payload = payload
    self.observedAt = observedAt
    self.sourceEventID = sourceEventID
    self.settlementID = settlementID
    self.tombstoneTarget = tombstoneTarget
  }

  func envelope(profile: RuntimeProfile) -> ExperienceSyncEnvelope {
    ExperienceSyncEnvelope(
      eventID: ExperienceEventID("schema-\(id)"),
      eventType: payload.eventType,
      profileID: profile.id,
      profileEpoch: profile.epoch,
      deletionEpoch: profile.deletionEpoch,
      profileSource: profile.source,
      originDeviceID: "iphone",
      originSequence: counter,
      revision: comprehensiveRevision(counter),
      observedAt: observedAt,
      authoredAt: comprehensiveNow.addingTimeInterval(TimeInterval(counter)),
      privacyClass: payload.expectedPrivacyClass,
      tombstone: tombstoneTarget.map {
        ExperienceTombstone(targetRecordID: $0, reason: .userDeleted)
      },
      sourceEventID: sourceEventID,
      settlementID: settlementID,
      payload: payload
    )
  }
}

private func comprehensiveEvent(
  _ id: String,
  profile: RuntimeProfile,
  sensingEpoch: SensingEpoch,
  kind: PassiveEventKind,
  observedOffset: TimeInterval,
  cooldownKey: String,
  revision: UInt64
) -> PassiveCompanionEvent {
  PassiveCompanionEvent(
    header: comprehensiveHeader(EventID(id), profile: profile),
    sensingEpoch: sensingEpoch,
    kind: kind,
    observedAt: comprehensiveNow.addingTimeInterval(observedOffset),
    confidence: .high,
    evidence: [EvidenceReference(id: EvidenceID("steps"), kind: .stepSummary)],
    presentationDeadline: comprehensiveNow.addingTimeInterval(observedOffset + 120),
    replacementKey: "motion-\(id)",
    taskCooldownKey: TaskCooldownKey(cooldownKey),
    memoryEligibility: .eligible,
    sceneID: "spring-valley",
    moriActionID: "walk.look-back",
    reminderRevision: comprehensiveRevision(revision)
  )
}

private func comprehensiveTask(
  _ id: String,
  event: PassiveCompanionEvent,
  profile: RuntimeProfile,
  revision: UInt64,
  reward: CoinRewardTier,
  completionPolicy: TaskCompletionPolicy = .automatic,
  expiresOffset: TimeInterval = 300
) -> TaskInstance {
  TaskInstance(
    header: comprehensiveHeader(TaskID(id), profile: profile),
    sourceEventID: event.header.recordID,
    kind: completionPolicy == .automatic ? .walkTogether : .reflectOnDay,
    cooldownKey: event.taskCooldownKey ?? TaskCooldownKey("missing-cooldown"),
    recommendationPriority: .recommended,
    completionPolicy: completionPolicy,
    issuedAt: comprehensiveNow.addingTimeInterval(TimeInterval(revision)),
    issuedRevision: comprehensiveRevision(revision),
    cooldownDuration: 900,
    expiresAt: comprehensiveNow.addingTimeInterval(expiresOffset),
    rewardTier: reward,
    settlementID: TaskSettlementID("settlement-\(id)"),
    lifecycleRevision: comprehensiveRevision(revision)
  )
}

private func comprehensiveCompletion(
  _ id: String,
  task: TaskInstance,
  profile: RuntimeProfile,
  revision: UInt64,
  method: TaskCompletionMethod = .automatic
) -> TaskTransition {
  TaskTransition(
    header: comprehensiveHeader(TaskTransitionID(id), profile: profile),
    taskID: task.header.recordID,
    revision: comprehensiveRevision(revision),
    state: .completed(
      method: method,
      at: comprehensiveNow.addingTimeInterval(TimeInterval(revision))
    ),
    settlementID: task.settlementID
  )
}

private let expectedPayloadCoverage: Set<String> = [
  "collectionOwnership",
  "collectionPurchase",
  "collectionTransition",
  "coinMigration",
  "coinReversal",
  "coinReward",
  "derivedFact",
  "identitySelection",
  "letter",
  "letterDelete",
  "letterRead",
  "memory",
  "memoryDelete",
  "passiveEvent",
  "passiveExpired",
  "passivePresented",
  "passiveReplaced",
  "task",
  "taskCompleted",
  "taskExpired",
]

private let expectedSchemaShapeCoverage: Set<String> = [
  "fact.approvedPlaceCategory.coarsePlaceClassifier",
  "fact.broadMotion.motionClassifier",
  "fact.foregroundInteraction.foregroundInteraction",
  "fact.sleepDuration.healthSummary",
  "fact.stepTotal.healthSummary",
  "factAuthorization.companion",
  "factAuthorization.displayOnly",
  "source.real",
  "taskCompletion.automatic",
  "taskCompletion.userConfirmed",
]

private func payloadCoverage(_ envelopes: [ExperienceSyncEnvelope]) -> Set<String> {
  Set(
    envelopes.map { envelope in
      switch envelope.payload {
      case .derivedFact:
        "derivedFact"
      case .passiveEvent:
        "passiveEvent"
      case .passiveEventTransition(let transition):
        switch transition.state {
        case .presented: "passivePresented"
        case .expired: "passiveExpired"
        case .replaced: "passiveReplaced"
        case .pending: "passivePending"
        }
      case .task:
        "task"
      case .taskTransition(let transition):
        switch transition.state {
        case .completed: "taskCompleted"
        case .expired: "taskExpired"
        case .active: "taskActive"
        }
      case .coinTransaction(let transaction):
        switch transaction.reason {
        case .taskReward: "coinReward"
        case .welcomeGrant: "coinWelcomeGrant"
        case .cosmeticPurchase: "coinPurchaseSplit"
        case .reversal: "coinReversal"
        case .migration: "coinMigration"
        }
      case .memory:
        "memory"
      case .memoryTransition:
        "memoryDelete"
      case .letter:
        "letter"
      case .letterTransition(let transition):
        switch transition.kind {
        case .read: "letterRead"
        case .delete: "letterDelete"
        }
      case .identitySelection:
        "identitySelection"
      case .collectionPurchase:
        "collectionPurchase"
      case .collectionOwnership:
        "collectionOwnership"
      case .collectionTransition:
        "collectionTransition"
      }
    }
  )
}

private func schemaShapeCoverage(_ envelopes: [ExperienceSyncEnvelope]) -> Set<String> {
  var coverage: Set<String> = []
  for envelope in envelopes {
    switch envelope.profileSource {
    case .real:
      coverage.insert("source.real")
    case .mock:
      coverage.insert("source.mock")
    }
    switch envelope.payload {
    case .derivedFact(let fact):
      let valueShape =
        switch fact.value {
        case .stepTotal: "stepTotal"
        case .sleepDuration: "sleepDuration"
        case .broadMotion: "broadMotion"
        case .approvedPlaceCategory: "approvedPlaceCategory"
        case .foregroundInteraction: "foregroundInteraction"
        }
      coverage.insert("fact.\(valueShape).\(fact.provenance.rawValue)")
      switch fact.authorization {
      case .displayOnly:
        coverage.insert("factAuthorization.displayOnly")
      case .companion:
        coverage.insert("factAuthorization.companion")
      }
    case .taskTransition(let transition):
      if case .completed(let method, _) = transition.state {
        coverage.insert("taskCompletion.\(method.rawValue)")
      }
    default:
      break
    }
  }
  return coverage
}

private func makeMockSchemaEnvelope() -> ExperienceSyncEnvelope {
  let epoch = ProfileEpoch(comprehensiveRevision(40))
  let profile = RuntimeProfile(
    id: ProfileID("schema-mock"),
    epoch: epoch,
    deletionEpoch: DeletionEpoch(
      requestID: DeletionRequestID("schema-mock-deletion-fence"),
      revision: comprehensiveRevision(40)
    ),
    source: .mock(
      scenarioID: MockScenarioID("ordinary-day"),
      selectionEpoch: epoch
    )
  )
  let fact = DerivedFactRecord(
    header: comprehensiveHeader(EvidenceID("mock-motion"), profile: profile),
    observedAt: comprehensiveNow,
    freshUntil: comprehensiveNow.addingTimeInterval(3_600),
    value: .broadMotion(.walking),
    provenance: .deterministicMock
  )
  return ExperienceSyncEnvelope(
    eventID: ExperienceEventID("schema-mock-motion"),
    eventType: .derivedFact,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    profileSource: profile.source,
    originDeviceID: "iphone",
    originSequence: 41,
    revision: comprehensiveRevision(41),
    observedAt: fact.observedAt,
    authoredAt: comprehensiveNow.addingTimeInterval(41),
    privacyClass: .approvedDerived,
    tombstone: nil,
    sourceEventID: nil,
    settlementID: nil,
    payload: .derivedFact(fact)
  )
}

private func canonicalComprehensiveFixture(_ name: String) throws -> Data {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: "json")
  )
  var data = try Data(contentsOf: url)
  while data.last == 0x0A || data.last == 0x0D {
    data.removeLast()
  }
  return data
}
