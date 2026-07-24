import Foundation
import MoriDomain
import MoriPersistence
import Testing

@Suite("Closed experience schema regressions")
struct ClosedExperienceSchemaRegressionTests {
  @Test("Codec rejects undeclared fields independently of sensitive-key deny lists")
  func rejectsUndeclaredHeartRateSamples() throws {
    let state = makeRegressionState()
    let envelope = makeFactEnvelope(in: state, revision: regressionRevision(1), sequence: 1)
    let codec = ExperienceEnvelopeCodec()
    let object = try #require(
      JSONSerialization.jsonObject(with: codec.encode(envelope)) as? [String: Any]
    )
    let undeclaredValues: [String: Any] = [
      "heartRateSamples": [["bpm": 72, "timestamp": 1_700_000_000]],
      "unexpectedDisplayHint": "not part of schema v1",
    ]

    for (key, value) in undeclaredValues {
      var injectedObject = object
      injectedObject[key] = value
      let injected = try JSONSerialization.data(withJSONObject: injectedObject)

      #expect(throws: ExperienceEnvelopeCodecError.self) {
        _ = try codec.decode(injected)
      }
    }
  }
}

@Suite("Terminal replay regressions")
struct TerminalReplayRegressionTests {
  @Test("A late read after letter deletion converges without remaining unresolved")
  func lateReadAfterDeleteIsConsumed() throws {
    let state = makeRegressionState()
    let fact = makeFactEnvelope(in: state, revision: regressionRevision(1), sequence: 1)
    let event = makePassiveEnvelope(in: state, revision: regressionRevision(2), sequence: 2)
    let letter = makeLetterEnvelope(in: state, revision: regressionRevision(3), sequence: 3)
    let deletion = makeLetterTransitionEnvelope(
      in: state,
      revision: regressionRevision(4),
      sequence: 4,
      id: "delete-letter",
      kind: .delete(at: regressionNow.addingTimeInterval(40))
    )
    let lateRead = makeLetterTransitionEnvelope(
      in: state,
      revision: regressionRevision(5),
      sequence: 5,
      id: "late-read-letter",
      kind: .read(at: regressionNow.addingTimeInterval(50))
    )
    let ledger = try ProfileLedger(
      initialState: state,
      envelopes: [lateRead, deletion, letter, event, fact]
    )

    let replay = ledger.replay()

    #expect(replay.unresolved.isEmpty)
    #expect(replay.state.letters.count == 1)
    #expect(replay.state.letters.first?.isDeleted == true)
    #expect(replay.state.letters.first?.isRead == false)
  }
}

private let regressionNow = Date(timeIntervalSince1970: 1_700_000_000)

private func regressionRevision(_ counter: UInt64) -> LamportRevision {
  LamportRevision(counter: counter, originDeviceID: "iphone")
}

private func regressionHeader<ID>(
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

private func makeRegressionState() -> ProfileState {
  let profile = RuntimeProfile(
    id: ProfileID("regression-real"),
    epoch: ProfileEpoch(regressionRevision(1)),
    deletionEpoch: DeletionEpoch(
      requestID: DeletionRequestID("regression-delete-fence"),
      revision: regressionRevision(1)
    ),
    source: .real
  )
  return ProfileState(
    header: regressionHeader(profile.id, in: profile),
    runtimeProfile: profile,
    companionSensingEnabled: true,
    currentSensingEpoch: SensingEpoch(regressionRevision(1)),
    selectedIdentity: .penguin,
    identityRevision: regressionRevision(1),
    coinLedger: CoinLedger(
      header: regressionHeader(CoinLedgerID("coins"), in: profile)
    ),
    collection: CollectionState(
      header: regressionHeader(CollectionID("collection"), in: profile)
    )
  )
}

private func makeFactEnvelope(
  in state: ProfileState,
  revision: LamportRevision,
  sequence: UInt64
) -> ExperienceSyncEnvelope {
  let profile = state.runtimeProfile
  let fact = DerivedFactRecord(
    header: regressionHeader(EvidenceID("steps"), in: profile),
    observedAt: regressionNow,
    freshUntil: regressionNow.addingTimeInterval(3_600),
    value: .stepTotal(3_250),
    provenance: .healthSummary,
    authorization: .companion(state.currentSensingEpoch)
  )
  return ExperienceSyncEnvelope(
    eventID: ExperienceEventID("experience-fact"),
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

private func makePassiveEnvelope(
  in state: ProfileState,
  revision: LamportRevision,
  sequence: UInt64
) -> ExperienceSyncEnvelope {
  let profile = state.runtimeProfile
  let event = PassiveCompanionEvent(
    header: regressionHeader(EventID("walk"), in: profile),
    sensingEpoch: state.currentSensingEpoch,
    kind: .sharedWalk,
    observedAt: regressionNow.addingTimeInterval(10),
    confidence: .high,
    evidence: [EvidenceReference(id: EvidenceID("steps"), kind: .stepSummary)],
    presentationDeadline: regressionNow.addingTimeInterval(130),
    replacementKey: "movement",
    taskCooldownKey: TaskCooldownKey("walk"),
    memoryEligibility: .eligible,
    sceneID: "spring-valley",
    moriActionID: "walk-together",
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

private func makeLetterEnvelope(
  in state: ProfileState,
  revision: LamportRevision,
  sequence: UInt64
) -> ExperienceSyncEnvelope {
  let profile = state.runtimeProfile
  let letter = LetterRecord(
    header: regressionHeader(LetterID("letter"), in: profile),
    source: .event(EventID("walk")),
    title: "今天，我们一起……",
    body: "刚才那段路走得好快，我差点跟不上。",
    deliveredAt: regressionNow.addingTimeInterval(20),
    authoredRevision: revision
  )
  return ExperienceSyncEnvelope(
    eventID: ExperienceEventID("experience-letter"),
    eventType: .letterDelivered,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    originDeviceID: revision.originDeviceID,
    originSequence: sequence,
    revision: revision,
    observedAt: letter.deliveredAt,
    authoredAt: letter.deliveredAt,
    privacyClass: .productState,
    tombstone: nil,
    sourceEventID: EventID("walk"),
    settlementID: nil,
    payload: .letter(letter)
  )
}

private func makeLetterTransitionEnvelope(
  in state: ProfileState,
  revision: LamportRevision,
  sequence: UInt64,
  id: String,
  kind: LetterTransitionKind
) -> ExperienceSyncEnvelope {
  let profile = state.runtimeProfile
  let transition = LetterTransition(
    header: regressionHeader(LetterTransitionID(id), in: profile),
    letterID: LetterID("letter"),
    revision: revision,
    kind: kind
  )
  let isDeletion: Bool
  if case .delete = kind {
    isDeletion = true
  } else {
    isDeletion = false
  }
  return ExperienceSyncEnvelope(
    eventID: ExperienceEventID("experience-\(id)"),
    eventType: isDeletion ? .letterDeleted : .letterRead,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    originDeviceID: revision.originDeviceID,
    originSequence: sequence,
    revision: revision,
    observedAt: nil,
    authoredAt: regressionNow.addingTimeInterval(TimeInterval(sequence * 10)),
    privacyClass: .productState,
    tombstone: isDeletion
      ? ExperienceTombstone(targetRecordID: "letter", reason: .userDeleted)
      : nil,
    sourceEventID: nil,
    settlementID: nil,
    payload: .letterTransition(transition)
  )
}
