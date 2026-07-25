import Foundation
import MoriDomain

enum ExperienceTestFixtures {
  static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

  static func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }

  static func revision(
    _ counter: UInt64,
    device: String = "iphone"
  ) -> LamportRevision {
    LamportRevision(counter: counter, originDeviceID: device)
  }

  static func profile() -> RuntimeProfile {
    let epoch = ProfileEpoch(revision(10, device: "profile-authority"))
    return RuntimeProfile(
      id: ProfileID("mock-normal-day"),
      epoch: epoch,
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("deletion-initial"),
        revision: revision(1, device: "deletion-authority")
      ),
      source: .mock(
        scenarioID: MockScenarioID("normal-day"),
        selectionEpoch: epoch
      )
    )
  }

  static func header<RecordID: Hashable & Codable & Sendable>(
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

  static func sensingEpoch() -> SensingEpoch {
    SensingEpoch(revision(20, device: "watch"))
  }

  static func fact(
    _ id: String,
    observedAt: Date,
    value: DerivedFactValue = .stepTotal(3_250),
    profile: RuntimeProfile = profile()
  ) -> DerivedFactRecord {
    DerivedFactRecord(
      header: header(EvidenceID(id), profile: profile),
      observedAt: observedAt,
      freshUntil: observedAt.addingTimeInterval(3_600),
      value: value,
      provenance: .deterministicMock,
      authorization: .companion(sensingEpoch())
    )
  }

  static func event(
    _ id: String,
    observedAt: Date,
    fact: DerivedFactRecord,
    kind: PassiveEventKind = .sharedWalk,
    deadline: Date? = nil,
    memoryEligibility: MemoryEligibility = .eligible,
    reminderState: ReminderState = .pending,
    profile: RuntimeProfile = profile()
  ) -> PassiveCompanionEvent {
    PassiveCompanionEvent(
      header: header(EventID(id), profile: profile),
      sensingEpoch: sensingEpoch(),
      kind: kind,
      observedAt: observedAt,
      confidence: .high,
      evidence: [
        EvidenceReference(
          id: fact.header.recordID,
          kind: fact.value.kind
        )
      ],
      presentationDeadline: deadline ?? observedAt.addingTimeInterval(120),
      replacementKey: "companion.latest",
      taskCooldownKey: nil,
      memoryEligibility: memoryEligibility,
      sceneID: "path.day",
      moriActionID: "companion.walk",
      reminderState: reminderState,
      reminderRevision: revision(30, device: "watch")
    )
  }

  static func state(
    facts: [DerivedFactRecord],
    events: [PassiveCompanionEvent],
    memories: [MemoryRecord] = [],
    sensingEnabled: Bool = true,
    profile: RuntimeProfile = profile()
  ) -> ProfileState {
    ProfileState(
      header: header(profile.id, profile: profile),
      runtimeProfile: profile,
      companionSensingEnabled: sensingEnabled,
      currentSensingEpoch: sensingEpoch(),
      selectedIdentity: .penguin,
      identityRevision: revision(2),
      derivedFacts: facts,
      passiveEvents: events,
      coinLedger: CoinLedger(
        header: header(CoinLedgerID("coins"), profile: profile)
      ),
      collection: CollectionState(
        header: header(CollectionID("collection"), profile: profile)
      ),
      memories: memories
    )
  }
}
