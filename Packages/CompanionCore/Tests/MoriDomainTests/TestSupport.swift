import Foundation

@testable import MoriDomain

enum MoriTestFixtures {
  static let now = Date(timeIntervalSince1970: 1_720_000_000)

  static func revision(
    _ counter: UInt64,
    device: String = "iphone"
  ) -> LamportRevision {
    LamportRevision(counter: counter, originDeviceID: device)
  }

  static func profile(
    _ suffix: String = "primary",
    profileEpoch: UInt64 = 10,
    deletionEpoch: UInt64 = 20,
    source: RuntimeProfileSource = .real
  ) -> RuntimeProfile {
    RuntimeProfile(
      id: ProfileID("profile-\(suffix)"),
      epoch: ProfileEpoch(revision(profileEpoch, device: "profile-authority")),
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("deletion-\(deletionEpoch)"),
        revision: revision(deletionEpoch, device: "deletion-authority")
      ),
      source: source
    )
  }

  static func mockProfile(
    _ suffix: String = "ordinary-day",
    selectionEpoch: UInt64 = 10
  ) -> RuntimeProfile {
    let epoch = ProfileEpoch(revision(selectionEpoch, device: "profile-authority"))
    return RuntimeProfile(
      id: ProfileID("mock-\(suffix)"),
      epoch: epoch,
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("deletion-20"),
        revision: revision(20, device: "deletion-authority")
      ),
      source: .mock(
        scenarioID: MockScenarioID(suffix),
        selectionEpoch: epoch
      )
    )
  }

  static func header<RecordID: Hashable & Codable & Sendable>(
    _ recordID: RecordID,
    profile: RuntimeProfile,
    schemaVersion: UInt16 = 1
  ) -> ProfileScopedRecordHeader<RecordID> {
    ProfileScopedRecordHeader(
      schemaVersion: schemaVersion,
      recordID: recordID,
      profileID: profile.id,
      profileEpoch: profile.epoch,
      deletionEpoch: profile.deletionEpoch
    )
  }

  static func state(
    profile: RuntimeProfile = profile(),
    sensingEnabled: Bool = true,
    sensingEpochCounter: UInt64 = 30
  ) -> ProfileState {
    let sensingEpoch = SensingEpoch(revision(sensingEpochCounter, device: "watch"))
    return ProfileState(
      header: header(profile.id, profile: profile),
      runtimeProfile: profile,
      companionSensingEnabled: sensingEnabled,
      currentSensingEpoch: sensingEpoch,
      selectedIdentity: .penguin,
      identityRevision: revision(1),
      coinLedger: CoinLedger(
        header: header(CoinLedgerID("coins"), profile: profile)
      ),
      collection: CollectionState(
        header: header(CollectionID("collection"), profile: profile)
      )
    )
  }

  static func fact(
    _ id: String = "steps",
    profile: RuntimeProfile = profile(),
    observedAt: Date = now,
    freshUntil: Date? = nil,
    value: DerivedFactValue = .stepTotal(3_250),
    provenance: EvidenceProvenance? = nil
  ) -> DerivedFactRecord {
    DerivedFactRecord(
      header: header(EvidenceID(id), profile: profile),
      observedAt: observedAt,
      freshUntil: freshUntil ?? observedAt.addingTimeInterval(3_600),
      value: value,
      provenance: provenance ?? (profile.isMock ? .deterministicMock : .healthSummary)
    )
  }

  static func event(
    _ id: String = "walk",
    profile: RuntimeProfile = profile(),
    sensingEpoch: SensingEpoch? = nil,
    fact: DerivedFactRecord? = nil,
    confidence: ConfidenceBand = .high,
    observedAt: Date = now,
    deadline: Date? = nil,
    cooldownKey: TaskCooldownKey? = TaskCooldownKey("walk-together"),
    kind: PassiveEventKind = .sharedWalk
  ) -> PassiveCompanionEvent {
    let evidenceFact = fact ?? self.fact(profile: profile, observedAt: observedAt)
    return PassiveCompanionEvent(
      header: header(EventID(id), profile: profile),
      sensingEpoch: sensingEpoch ?? SensingEpoch(revision(30, device: "watch")),
      kind: kind,
      observedAt: observedAt,
      confidence: confidence,
      evidence: [
        EvidenceReference(
          id: evidenceFact.header.recordID,
          kind: evidenceFact.value.kind
        )
      ],
      presentationDeadline: deadline ?? observedAt.addingTimeInterval(120),
      replacementKey: "motion",
      taskCooldownKey: cooldownKey,
      memoryEligibility: .eligible,
      sceneID: "spring-valley",
      moriActionID: "walk.look-back",
      reminderRevision: revision(40, device: "watch")
    )
  }

  static func task(
    _ id: String = "task-walk",
    event: PassiveCompanionEvent,
    profile: RuntimeProfile = profile(),
    issuedAt: Date = now,
    issuedRevision: LamportRevision = revision(50),
    policy: TaskCompletionPolicy = .automatic,
    priority: RecommendationPriority = .recommended,
    cooldownDuration: TimeInterval = 900,
    reward: CoinRewardTier = .standard
  ) -> TaskInstance {
    TaskInstance(
      header: header(TaskID(id), profile: profile),
      sourceEventID: event.header.recordID,
      kind: .walkTogether,
      cooldownKey: event.taskCooldownKey ?? TaskCooldownKey("walk-together"),
      recommendationPriority: priority,
      completionPolicy: policy,
      issuedAt: issuedAt,
      issuedRevision: issuedRevision,
      cooldownDuration: cooldownDuration,
      expiresAt: issuedAt.addingTimeInterval(3_600),
      rewardTier: reward,
      settlementID: TaskSettlementID("settlement-\(id)"),
      lifecycleRevision: issuedRevision
    )
  }

  static func taskTransition(
    _ id: String,
    task: TaskInstance,
    profile: RuntimeProfile,
    revision: LamportRevision,
    method: TaskCompletionMethod
  ) -> TaskTransition {
    TaskTransition(
      header: header(TaskTransitionID(id), profile: profile),
      taskID: task.header.recordID,
      revision: revision,
      state: .completed(method: method, at: now.addingTimeInterval(300)),
      settlementID: task.settlementID
    )
  }

  static func reward(
    _ id: String,
    settlementID: TaskSettlementID,
    profile: RuntimeProfile,
    revision: LamportRevision,
    tier: CoinRewardTier
  ) -> CoinTransaction {
    CoinTransaction(
      header: header(CoinTransactionID(id), profile: profile),
      revision: revision,
      authoredAt: now,
      direction: .credit,
      amount: tier.rawValue,
      reason: .taskReward(settlementID)
    )
  }

  static func letter(
    _ id: String = "letter-1",
    profile: RuntimeProfile = profile()
  ) -> LetterRecord {
    LetterRecord(
      header: header(LetterID(id), profile: profile),
      source: .event(EventID("walk")),
      title: "今天，我们一起……",
      body: "刚才那段路走得好快，我差点跟不上。",
      deliveredAt: now,
      authoredRevision: revision(60)
    )
  }

  static func letterTransition(
    _ id: String,
    letter: LetterRecord,
    profile: RuntimeProfile,
    revision: LamportRevision,
    kind: LetterTransitionKind
  ) -> LetterTransition {
    LetterTransition(
      header: header(LetterTransitionID(id), profile: profile),
      letterID: letter.header.recordID,
      revision: revision,
      kind: kind
    )
  }

  static func memory(
    profile: RuntimeProfile = profile(),
    day: LocalDay = LocalDay("2026-07-24"),
    timeZoneIdentifier: String = "Asia/Shanghai"
  ) -> MemoryRecord {
    let id = MemoryID.daily(
      profileID: profile.id,
      profileEpoch: profile.epoch,
      localDay: day,
      timeZoneIdentifier: timeZoneIdentifier
    )
    return MemoryRecord(
      header: header(id, profile: profile),
      localDay: day,
      timeZoneIdentifier: timeZoneIdentifier,
      authoredRevision: revision(70)
    )
  }

  static func memoryContent(
    narrative: String = "今天我们经过了一段很长的路。",
    sealedAt: Date = now
  ) -> SealedMemoryContent {
    SealedMemoryContent(
      facts: [
        MemoryFactReference(evidenceID: EvidenceID("steps"), kind: .stepSummary)
      ],
      narrative: narrative,
      sceneID: "spring-valley",
      moriActionID: "rest.sit",
      sealedAt: sealedAt
    )
  }

  static func conversation(
    _ id: String,
    profile: RuntimeProfile = profile(),
    revision: LamportRevision = revision(80),
    content: String = "今天散步的时候很开心。"
  ) -> ConversationRecord {
    ConversationRecord(
      header: header(ConversationRecordID(id), profile: profile),
      conversationID: ConversationID("main"),
      role: .user,
      content: content,
      localTime: now,
      referencedMemoryIDs: [],
      revision: revision
    )
  }

  static func identitySelectionEnvelope(
    profile: RuntimeProfile = profile(),
    eventID: ExperienceEventID = ExperienceEventID("experience-identity"),
    schemaVersion: UInt16 = 1,
    privacyClass: ExperiencePrivacyClass = .productState,
    tombstone: ExperienceTombstone? = nil
  ) -> ExperienceSyncEnvelope {
    let selection = IdentitySelectionRecord(
      header: header(IdentitySelectionID("identity-selection"), profile: profile),
      identity: .polarBear,
      revision: revision(90)
    )
    return ExperienceSyncEnvelope(
      schemaVersion: schemaVersion,
      eventID: eventID,
      eventType: .identitySelected,
      profileID: profile.id,
      profileEpoch: profile.epoch,
      deletionEpoch: profile.deletionEpoch,
      originDeviceID: "iphone",
      originSequence: 1,
      revision: revision(90),
      observedAt: nil,
      authoredAt: now,
      privacyClass: privacyClass,
      tombstone: tombstone,
      sourceEventID: nil,
      settlementID: nil,
      payload: .identitySelection(selection)
    )
  }
}

struct DeterministicGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: Int) {
    state = UInt64(truncatingIfNeeded: seed) &+ 0x9E37_79B9_7F4A_7C15
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
