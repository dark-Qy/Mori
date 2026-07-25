import Foundation
import MoriDomain
import MoriPersistence
import MoriRuntime
import Testing

@Suite("Task settlement runtime")
struct TaskSettlementRuntimeTests {
  private let completedAt =
    ExperienceTestFixtures.date("2026-07-24T12:30:00Z")

  @Test("Completion and reward IDs are deterministic and ordered")
  func deterministicIDsAndOrdering() async throws {
    let first = try await makeSettlementFixture()
    let second = try await makeSettlementFixture()
    let firstRuntime = TaskSettlementRuntime(
      originDeviceID: "iphone",
      store: first.runtime
    )
    let secondRuntime = TaskSettlementRuntime(
      originDeviceID: "iphone",
      store: second.runtime
    )

    let firstResult = try await firstRuntime.complete(
      taskID: first.taskID,
      method: .automatic,
      at: completedAt
    )
    let secondResult = try await secondRuntime.complete(
      taskID: second.taskID,
      method: .automatic,
      at: completedAt
    )
    let retry = try await firstRuntime.complete(
      taskID: first.taskID,
      method: .automatic,
      at: completedAt
    )

    #expect(firstResult.completionEventID == secondResult.completionEventID)
    #expect(firstResult.rewardEventID == secondResult.rewardEventID)
    #expect(firstResult.didRecordCompletion)
    #expect(firstResult.didRecordReward)
    #expect(retry.completionEventID == firstResult.completionEventID)
    #expect(retry.rewardEventID == firstResult.rewardEventID)
    #expect(retry.didRecordCompletion == false)
    #expect(retry.didRecordReward == false)

    let replay = try await first.runtime.currentReplay()
    #expect(replay.state.coinLedger.balance == CoinRewardTier.standard.rawValue)
    #expect(replay.state.coinLedger.transactions.count == 1)
    #expect(
      Array(replay.state.experienceLedger.suffix(2).map(\.eventType))
        == [.taskCompleted, .coinEarned]
    )
  }

  @Test("Startup repair rewards a completed task after interruption")
  func startupRepairAfterCompletionOnly() async throws {
    let fixture = try await makeSettlementFixture()
    let interruptedStore = FailBeforeRewardStore(runtime: fixture.runtime)
    let interrupted = TaskSettlementRuntime(
      originDeviceID: "iphone",
      store: interruptedStore
    )

    await #expect(throws: SettlementInterruption.self) {
      _ = try await interrupted.complete(
        taskID: fixture.taskID,
        method: .automatic,
        at: completedAt
      )
    }
    let completionOnly = try await fixture.runtime.currentReplay()
    #expect(
      completionOnly.state.tasks.first?.lifecycle.isCompleted == true
    )
    #expect(completionOnly.state.coinLedger.balance == 0)

    let relaunched = TaskSettlementRuntime(
      originDeviceID: "iphone",
      store: fixture.runtime
    )
    let report = try await relaunched.repairIncompleteSettlements()
    let repaired = try await fixture.runtime.currentReplay()

    #expect(report.scannedCompletedTaskCount == 1)
    #expect(report.repairedSettlementIDs == [fixture.settlementID])
    #expect(repaired.state.coinLedger.balance == CoinRewardTier.standard.rawValue)
    #expect(repaired.state.coinLedger.transactions.count == 1)
  }

  @Test("Phone and Watch completion converge to one settlement reward")
  func simultaneousPeerCompletionIsIdempotent() async throws {
    let phone = try await makeSettlementFixture()
    let watch = try await makeSettlementFixture()
    try await drain(phone.runtime, to: watch.runtime)
    try await drain(watch.runtime, to: phone.runtime)
    let phoneSettlement = TaskSettlementRuntime(
      originDeviceID: "iphone",
      store: phone.runtime
    )
    let watchSettlement = TaskSettlementRuntime(
      originDeviceID: "watch",
      store: watch.runtime
    )

    async let phoneResult = phoneSettlement.complete(
      taskID: phone.taskID,
      method: .automatic,
      at: completedAt
    )
    async let watchResult = watchSettlement.complete(
      taskID: watch.taskID,
      method: .automatic,
      at: completedAt
    )
    let (phoneLocal, watchLocal) = try await (phoneResult, watchResult)
    #expect(phoneLocal.rewardEventID != watchLocal.rewardEventID)
    #expect(phoneLocal.settlementID == watchLocal.settlementID)

    try await drain(phone.runtime, to: watch.runtime)
    try await drain(watch.runtime, to: phone.runtime)
    let phoneReplay = try await phone.runtime.currentReplay()
    let watchReplay = try await watch.runtime.currentReplay()

    #expect(phoneReplay.state.coinLedger.balance == CoinRewardTier.standard.rawValue)
    #expect(watchReplay.state.coinLedger.balance == CoinRewardTier.standard.rawValue)
    #expect(phoneReplay.state.coinLedger.transactions.count == 1)
    #expect(watchReplay.state.coinLedger.transactions.count == 1)
    #expect(
      phoneReplay.state.experienceLedger.filter {
        $0.eventType == .coinEarned
      }.count == 2
    )
    #expect(phoneReplay.unresolved.isEmpty)
    #expect(watchReplay.unresolved.isEmpty)
  }

  @Test("A peer repairs completion-only state after synchronization")
  func postSyncRepair() async throws {
    let phone = try await makeSettlementFixture()
    let watch = try await makeSettlementFixture()
    try await drain(phone.runtime, to: watch.runtime)
    try await drain(watch.runtime, to: phone.runtime)
    let interrupted = TaskSettlementRuntime(
      originDeviceID: "iphone",
      store: FailBeforeRewardStore(runtime: phone.runtime)
    )

    await #expect(throws: SettlementInterruption.self) {
      _ = try await interrupted.complete(
        taskID: phone.taskID,
        method: .automatic,
        at: completedAt
      )
    }
    try await drain(phone.runtime, to: watch.runtime)
    let completionOnly = try await watch.runtime.currentReplay()
    #expect(completionOnly.state.tasks.first?.lifecycle.isCompleted == true)
    #expect(completionOnly.state.coinLedger.balance == 0)

    let watchSettlement = TaskSettlementRuntime(
      originDeviceID: "watch",
      store: watch.runtime
    )
    let report = try await watchSettlement.repairIncompleteSettlements()
    #expect(report.repairedSettlementIDs == [watch.settlementID])
    try await drain(watch.runtime, to: phone.runtime)

    let phoneReplay = try await phone.runtime.currentReplay()
    let watchReplay = try await watch.runtime.currentReplay()
    #expect(phoneReplay.state.coinLedger.balance == CoinRewardTier.standard.rawValue)
    #expect(watchReplay.state.coinLedger.balance == CoinRewardTier.standard.rawValue)
    #expect(phoneReplay.state.coinLedger.transactions.count == 1)
    #expect(watchReplay.state.coinLedger.transactions.count == 1)
  }

  @Test("Synchronization recovers a reward written before outbox interruption")
  func ledgerToOutboxInterruptionRecoversOnSync() async throws {
    let phone = try await makeSettlementFixture()
    let watch = try await makeSettlementFixture()
    try await drain(phone.runtime, to: watch.runtime)
    try await drain(watch.runtime, to: phone.runtime)
    let interruptedStore = LedgerOnlyRewardStore(
      runtime: phone.runtime,
      ledger: phone.ledger
    )
    let settlement = TaskSettlementRuntime(
      originDeviceID: "iphone",
      store: interruptedStore
    )

    await #expect(throws: SettlementInterruption.self) {
      _ = try await settlement.complete(
        taskID: phone.taskID,
        method: .automatic,
        at: completedAt
      )
    }
    #expect(try await phone.runtime.pendingEventCount() == 1)
    #expect(
      try await phone.runtime.currentReplay().state.coinLedger.balance
        == CoinRewardTier.standard.rawValue
    )

    try await drain(phone.runtime, to: watch.runtime)
    let watchReplay = try await watch.runtime.currentReplay()
    #expect(watchReplay.state.coinLedger.balance == CoinRewardTier.standard.rawValue)
    #expect(watchReplay.state.coinLedger.transactions.count == 1)
    #expect(try await phone.runtime.pendingEventCount() == 0)
  }
}

private typealias SettlementLedger =
  ProfileLedgerRepository<InMemoryProfileLedgerStorage>
private typealias SettlementSyncRuntime =
  ExperienceSyncRuntime<
    InMemoryExperienceSyncOutboxStorage,
    SettlementLedger
  >

private struct SettlementFixture {
  let runtime: SettlementSyncRuntime
  let ledger: SettlementLedger
  let taskID: TaskID
  let settlementID: TaskSettlementID
}

private func makeSettlementFixture() async throws -> SettlementFixture {
  let profile = ExperienceTestFixtures.profile()
  let ledger = SettlementLedger(
    storage: InMemoryProfileLedgerStorage(),
    initialState: ExperienceTestFixtures.state(facts: [], events: [])
  )
  let runtime = SettlementSyncRuntime(
    profile: profile,
    outboxStorage: InMemoryExperienceSyncOutboxStorage(),
    ledger: ledger
  )
  let issuedAt = ExperienceTestFixtures.date("2026-07-24T12:00:00Z")
  let sourceEventID = EventID("settlement-source-event")
  let taskID = TaskID("settlement-task")
  let settlementID = TaskSettlementID("settlement-task-v1")
  let cooldownKey = TaskCooldownKey("walk-together")
  let fact = DerivedFactRecord(
    header: ExperienceTestFixtures.header(
      EvidenceID("settlement-source-fact"),
      profile: profile
    ),
    observedAt: issuedAt,
    freshUntil: issuedAt.addingTimeInterval(3_600),
    value: .stepTotal(3_250),
    provenance: .deterministicMock,
    authorization: .companion(ExperienceTestFixtures.sensingEpoch())
  )
  let event = PassiveCompanionEvent(
    header: ExperienceTestFixtures.header(sourceEventID, profile: profile),
    sensingEpoch: ExperienceTestFixtures.sensingEpoch(),
    kind: .sharedWalk,
    observedAt: issuedAt,
    confidence: .high,
    evidence: [
      EvidenceReference(
        id: fact.header.recordID,
        kind: fact.value.kind
      )
    ],
    presentationDeadline: issuedAt.addingTimeInterval(120),
    replacementKey: "companion.latest",
    taskCooldownKey: cooldownKey,
    memoryEligibility: .eligible,
    sceneID: "path.day",
    moriActionID: "companion.walk",
    reminderState: .pending,
    reminderRevision: ExperienceTestFixtures.revision(22, device: "seed")
  )
  let taskRevision = ExperienceTestFixtures.revision(23, device: "seed")
  let task = TaskInstance(
    header: ExperienceTestFixtures.header(taskID, profile: profile),
    sourceEventID: sourceEventID,
    kind: .walkTogether,
    cooldownKey: cooldownKey,
    recommendationPriority: .recommended,
    completionPolicy: .automatic,
    issuedAt: issuedAt,
    issuedRevision: taskRevision,
    cooldownDuration: 3_600,
    expiresAt: issuedAt.addingTimeInterval(3_600),
    rewardTier: .standard,
    settlementID: settlementID,
    lifecycleRevision: taskRevision
  )
  let seed: [ExperienceSyncEnvelope] = [
    settlementEnvelope(
      id: "settlement-fact-envelope",
      originSequence: 1,
      revisionCounter: 21,
      authoredAt: issuedAt,
      profile: profile,
      observedAt: issuedAt,
      payload: .derivedFact(fact)
    ),
    settlementEnvelope(
      id: "settlement-event-envelope",
      originSequence: 2,
      revisionCounter: 22,
      authoredAt: issuedAt,
      profile: profile,
      observedAt: issuedAt,
      payload: .passiveEvent(event)
    ),
    settlementEnvelope(
      id: "settlement-task-envelope",
      originSequence: 3,
      revisionCounter: 23,
      authoredAt: issuedAt,
      profile: profile,
      observedAt: issuedAt,
      sourceEventID: sourceEventID,
      settlementID: settlementID,
      payload: .task(task)
    ),
  ]
  for envelope in seed {
    try await runtime.recordLocal(envelope)
  }
  return SettlementFixture(
    runtime: runtime,
    ledger: ledger,
    taskID: taskID,
    settlementID: settlementID
  )
}

private func settlementEnvelope(
  id: String,
  originSequence: UInt64,
  revisionCounter: UInt64,
  authoredAt: Date,
  profile: RuntimeProfile,
  observedAt: Date?,
  sourceEventID: EventID? = nil,
  settlementID: TaskSettlementID? = nil,
  payload: ExperienceSyncPayload
) -> ExperienceSyncEnvelope {
  ExperienceSyncEnvelope(
    eventID: ExperienceEventID(id),
    eventType: payload.eventType,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    profileSource: profile.source,
    originDeviceID: "seed",
    originSequence: originSequence,
    revision: ExperienceTestFixtures.revision(
      revisionCounter,
      device: "seed"
    ),
    observedAt: observedAt,
    authoredAt: authoredAt,
    privacyClass: payload.expectedPrivacyClass,
    tombstone: nil,
    sourceEventID: sourceEventID,
    settlementID: settlementID,
    payload: payload
  )
}

private struct SettlementTransport: ExperienceSyncTransport {
  let receiver: SettlementSyncRuntime

  func exchange(_ transferData: Data) async throws -> Data {
    try await receiver.receive(transferData)
  }
}

private func drain(
  _ sender: SettlementSyncRuntime,
  to receiver: SettlementSyncRuntime
) async throws {
  let transport = SettlementTransport(receiver: receiver)
  while try await sender.pendingEventCount() > 0 {
    _ = try await sender.synchronize(using: transport)
  }
}

private enum SettlementInterruption: Error {
  case beforeReward
  case afterRewardLedgerWrite
}

private actor FailBeforeRewardStore: TaskSettlementEventStore {
  private let runtime: SettlementSyncRuntime

  init(runtime: SettlementSyncRuntime) {
    self.runtime = runtime
  }

  func currentLedger() async throws -> ProfileLedger {
    try await runtime.currentLedger()
  }

  func recordLocal(_ envelope: ExperienceSyncEnvelope) async throws {
    if envelope.eventType == .coinEarned {
      throw SettlementInterruption.beforeReward
    }
    try await runtime.recordLocal(envelope)
  }
}

private actor LedgerOnlyRewardStore: TaskSettlementEventStore {
  private let runtime: SettlementSyncRuntime
  private let ledger: SettlementLedger
  private var didInterruptReward = false

  init(
    runtime: SettlementSyncRuntime,
    ledger: SettlementLedger
  ) {
    self.runtime = runtime
    self.ledger = ledger
  }

  func currentLedger() async throws -> ProfileLedger {
    try await runtime.currentLedger()
  }

  func recordLocal(_ envelope: ExperienceSyncEnvelope) async throws {
    if envelope.eventType == .coinEarned, didInterruptReward == false {
      didInterruptReward = true
      _ = try await ledger.append(envelope)
      throw SettlementInterruption.afterRewardLedgerWrite
    }
    try await runtime.recordLocal(envelope)
  }
}
