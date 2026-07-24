import Foundation
import MoriDomain
import MoriPersistence
import Testing

@Suite("Sensing authority replay boundary")
struct SensingReplayBoundaryTests {
  @Test("Accepted history survives disable, re-enable, and repository restart")
  func acceptedHistorySurvivesAuthorityChanges() async throws {
    let initial = try sensingState()
    let storage = InMemoryProfileLedgerStorage()
    let first = ProfileLedgerRepository(storage: storage, initialState: initial)
    let fact = sensingFactEnvelope(
      id: "accepted-fact-envelope",
      factID: "accepted-steps",
      authorization: .companion(initial.currentSensingEpoch),
      state: initial,
      revision: sensingRevision(2),
      sequence: 1
    )
    let event = sensingEventEnvelope(
      id: "accepted-event-envelope",
      eventID: "accepted-walk",
      factID: "accepted-steps",
      epoch: initial.currentSensingEpoch,
      state: initial,
      revision: sensingRevision(3),
      sequence: 2
    )

    _ = try await first.append(fact)
    _ = try await first.append(event)
    #expect(
      try await first.setCompanionSensing(
        enabled: false,
        epoch: SensingEpoch(sensingRevision(4)),
        effectiveAt: sensingNow.addingTimeInterval(120)
      ) == .applied
    )
    #expect(
      try await first.setCompanionSensing(
        enabled: true,
        epoch: SensingEpoch(sensingRevision(5)),
        effectiveAt: sensingNow.addingTimeInterval(180)
      ) == .applied
    )

    let beforeRestart = try await first.currentReplay()
    #expect(beforeRestart.unresolved.isEmpty)
    #expect(
      beforeRestart.state.derivedFacts.map(\.header.recordID) == [EvidenceID("accepted-steps")])
    #expect(beforeRestart.state.passiveEvents.map(\.header.recordID) == [EventID("accepted-walk")])
    #expect(beforeRestart.state.passiveEvents.first?.reminderState.isTerminal == true)
    #expect(beforeRestart.state.currentSensingEpoch == SensingEpoch(sensingRevision(5)))
    #expect(beforeRestart.state.validate() == nil)

    let restarted = ProfileLedgerRepository(storage: storage, initialState: initial)
    let afterRestart = try await restarted.currentReplay()
    #expect(afterRestart == beforeRestart)
    #expect(afterRestart.state.experienceLedger.map(\.eventID) == [fact.eventID, event.eventID])
  }

  @Test("A late peer envelope from a revoked epoch is rejected before persistence")
  func lateRevokedPeerEnvelopeIsRejected() async throws {
    let initial = try sensingState()
    let storage = InMemoryProfileLedgerStorage()
    let repository = ProfileLedgerRepository(storage: storage, initialState: initial)
    let acceptedFact = sensingFactEnvelope(
      id: "accepted-fact-envelope",
      factID: "accepted-steps",
      authorization: .companion(initial.currentSensingEpoch),
      state: initial,
      revision: sensingRevision(2),
      sequence: 1
    )
    _ = try await repository.append(acceptedFact)
    #expect(
      try await repository.setCompanionSensing(
        enabled: false,
        epoch: SensingEpoch(sensingRevision(4)),
        effectiveAt: sensingNow.addingTimeInterval(120)
      ) == .applied
    )

    let lateFact = sensingFactEnvelope(
      id: "late-peer-fact-envelope",
      factID: "late-peer-steps",
      authorization: .companion(initial.currentSensingEpoch),
      state: initial,
      revision: sensingRevision(6, device: "watch"),
      sequence: 1
    )
    await expectSensingRejection(lateFact, from: repository)

    let lateEvent = sensingEventEnvelope(
      id: "late-peer-event-envelope",
      eventID: "late-peer-walk",
      factID: "accepted-steps",
      epoch: initial.currentSensingEpoch,
      state: initial,
      revision: sensingRevision(7, device: "watch"),
      sequence: 2
    )
    await expectSensingRejection(lateEvent, from: repository)

    let ledger = try await repository.currentLedger()
    #expect(ledger.envelopes == [acceptedFact])
  }

  @Test("Display evidence captured while disabled never backfills companion memory eligibility")
  func disabledIntervalDoesNotBackfill() async throws {
    let initial = try sensingState()
    let storage = InMemoryProfileLedgerStorage()
    let repository = ProfileLedgerRepository(storage: storage, initialState: initial)
    let disabledEpoch = SensingEpoch(sensingRevision(4))
    #expect(
      try await repository.setCompanionSensing(
        enabled: false,
        epoch: disabledEpoch,
        effectiveAt: sensingNow
      ) == .applied
    )

    let displayOnly = sensingFactEnvelope(
      id: "disabled-display-envelope",
      factID: "disabled-display-steps",
      authorization: .displayOnly,
      state: initial,
      revision: sensingRevision(5),
      sequence: 1
    )
    _ = try await repository.append(displayOnly)

    let forbiddenCompanionFact = sensingFactEnvelope(
      id: "disabled-companion-envelope",
      factID: "disabled-companion-steps",
      authorization: .companion(disabledEpoch),
      state: initial,
      revision: sensingRevision(6),
      sequence: 2
    )
    await expectSensingRejection(forbiddenCompanionFact, from: repository)

    let reenabledEpoch = SensingEpoch(sensingRevision(7))
    #expect(
      try await repository.setCompanionSensing(
        enabled: true,
        epoch: reenabledEpoch,
        effectiveAt: sensingNow.addingTimeInterval(60)
      ) == .applied
    )
    let backfillEvent = sensingEventEnvelope(
      id: "disabled-backfill-event-envelope",
      eventID: "disabled-backfill-walk",
      factID: "disabled-display-steps",
      epoch: reenabledEpoch,
      state: initial,
      revision: sensingRevision(8),
      sequence: 3
    )

    do {
      _ = try await repository.append(backfillEvent)
      Issue.record("display-only evidence must not become companion-authorized after re-enable")
    } catch {
      #expect(
        error as? ProfileLedgerError
          == .invalidEnvelope(backfillEvent.eventID, .invalidRecord)
      )
    }

    let replay = try await repository.currentReplay()
    #expect(replay.unresolved.isEmpty)
    #expect(replay.state.derivedFacts.count == 1)
    #expect(replay.state.derivedFacts.first?.authorization == .displayOnly)
    #expect(replay.state.passiveEvents.isEmpty)
    #expect(replay.state.memories.isEmpty)
    #expect(replay.state.validate() == nil)
  }

  @Test("A late presented transition cannot revive a superseded glance")
  func latePresentedTransitionLosesToDisable() async throws {
    let initial = try sensingState()
    let storage = InMemoryProfileLedgerStorage()
    let repository = ProfileLedgerRepository(storage: storage, initialState: initial)
    let fact = sensingFactEnvelope(
      id: "accepted-fact-envelope",
      factID: "accepted-steps",
      authorization: .companion(initial.currentSensingEpoch),
      state: initial,
      revision: sensingRevision(2),
      sequence: 1
    )
    let event = sensingEventEnvelope(
      id: "accepted-event-envelope",
      eventID: "accepted-walk",
      factID: "accepted-steps",
      epoch: initial.currentSensingEpoch,
      state: initial,
      revision: sensingRevision(3),
      sequence: 2
    )
    _ = try await repository.append(fact)
    _ = try await repository.append(event)
    #expect(
      try await repository.setCompanionSensing(
        enabled: false,
        epoch: SensingEpoch(sensingRevision(4)),
        effectiveAt: sensingNow.addingTimeInterval(120)
      ) == .applied
    )
    let presented = sensingPresentedEnvelope(
      eventID: "accepted-walk",
      profile: initial.runtimeProfile,
      revision: sensingRevision(5, device: "watch")
    )

    await expectSensingRejection(presented, from: repository)

    let replay = try await repository.currentReplay()
    #expect(replay.state.passiveEvents.first?.reminderState.isTerminal == true)
    if case .expired = replay.state.passiveEvents.first?.reminderState {
      // Expected: the sensing epoch remains authoritative over a late presentation.
    } else {
      Issue.record("The superseded glance must remain expired")
    }
  }
}

private let sensingNow = Date(timeIntervalSince1970: 1_700_000_000)

private func sensingState() throws -> ProfileState {
  let profile = RuntimeProfile(
    id: ProfileID("sensing-real"),
    epoch: ProfileEpoch(sensingRevision(1)),
    deletionEpoch: DeletionEpoch(
      requestID: DeletionRequestID("sensing-delete-fence"),
      revision: sensingRevision(1)
    ),
    source: .real
  )
  let state = ProfileState(
    header: sensingHeader(ProfileID("sensing-real"), profile: profile),
    runtimeProfile: profile,
    companionSensingEnabled: true,
    currentSensingEpoch: SensingEpoch(sensingRevision(1)),
    selectedIdentity: .penguin,
    identityRevision: sensingRevision(1),
    coinLedger: CoinLedger(
      header: sensingHeader(CoinLedgerID("coins"), profile: profile)
    ),
    collection: CollectionState(
      header: sensingHeader(CollectionID("collection"), profile: profile)
    )
  )
  if let rejection = state.validate() {
    throw rejection
  }
  return state
}

private func sensingFactEnvelope(
  id: String,
  factID: String,
  authorization: EvidenceAuthorization,
  state: ProfileState,
  revision: LamportRevision,
  sequence: UInt64
) -> ExperienceSyncEnvelope {
  let fact = DerivedFactRecord(
    header: sensingHeader(EvidenceID(factID), profile: state.runtimeProfile),
    observedAt: sensingNow,
    freshUntil: sensingNow.addingTimeInterval(3_600),
    value: .stepTotal(3_250),
    provenance: .healthSummary,
    authorization: authorization
  )
  return sensingEnvelope(
    id: id,
    payload: .derivedFact(fact),
    profile: state.runtimeProfile,
    revision: revision,
    sequence: sequence,
    observedAt: fact.observedAt
  )
}

private func sensingEventEnvelope(
  id: String,
  eventID: String,
  factID: String,
  epoch: SensingEpoch,
  state: ProfileState,
  revision: LamportRevision,
  sequence: UInt64
) -> ExperienceSyncEnvelope {
  let event = PassiveCompanionEvent(
    header: sensingHeader(EventID(eventID), profile: state.runtimeProfile),
    sensingEpoch: epoch,
    kind: .sharedWalk,
    observedAt: sensingNow.addingTimeInterval(30),
    confidence: .high,
    evidence: [EvidenceReference(id: EvidenceID(factID), kind: .stepSummary)],
    presentationDeadline: sensingNow.addingTimeInterval(150),
    replacementKey: "movement",
    taskCooldownKey: TaskCooldownKey("walk"),
    memoryEligibility: .eligible,
    sceneID: "spring-valley",
    moriActionID: "walk",
    reminderRevision: revision
  )
  return sensingEnvelope(
    id: id,
    payload: .passiveEvent(event),
    profile: state.runtimeProfile,
    revision: revision,
    sequence: sequence,
    observedAt: event.observedAt
  )
}

private func sensingPresentedEnvelope(
  eventID: String,
  profile: RuntimeProfile,
  revision: LamportRevision
) -> ExperienceSyncEnvelope {
  let transition = PassiveEventTransition(
    header: sensingHeader(
      EventTransitionID("presented-\(eventID)"),
      profile: profile
    ),
    eventID: EventID(eventID),
    revision: revision,
    state: .presented(at: sensingNow.addingTimeInterval(121))
  )
  return sensingEnvelope(
    id: "presented-\(eventID)-envelope",
    payload: .passiveEventTransition(transition),
    profile: profile,
    revision: revision,
    sequence: 3,
    observedAt: nil
  )
}

private func sensingEnvelope(
  id: String,
  payload: ExperienceSyncPayload,
  profile: RuntimeProfile,
  revision: LamportRevision,
  sequence: UInt64,
  observedAt: Date?
) -> ExperienceSyncEnvelope {
  ExperienceSyncEnvelope(
    eventID: ExperienceEventID(id),
    eventType: payload.eventType,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch,
    profileSource: profile.source,
    originDeviceID: revision.originDeviceID,
    originSequence: sequence,
    revision: revision,
    observedAt: observedAt,
    authoredAt: sensingNow.addingTimeInterval(Double(sequence)),
    privacyClass: payload.expectedPrivacyClass,
    tombstone: nil,
    sourceEventID: nil,
    settlementID: nil,
    payload: payload
  )
}

private func expectSensingRejection<Storage: ProfileLedgerStorage>(
  _ envelope: ExperienceSyncEnvelope,
  from repository: ProfileLedgerRepository<Storage>
) async {
  do {
    _ = try await repository.append(envelope)
    Issue.record("a late envelope from a revoked sensing epoch must be rejected")
  } catch {
    #expect(
      error as? ProfileLedgerError
        == .invalidEnvelope(envelope.eventID, .sensingEpochMismatch)
    )
  }
}

private func sensingHeader<ID>(
  _ id: ID,
  profile: RuntimeProfile
) -> ProfileScopedRecordHeader<ID> where ID: Codable & Hashable & Sendable {
  ProfileScopedRecordHeader(
    recordID: id,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch
  )
}

private func sensingRevision(
  _ counter: UInt64,
  device: String = "iphone"
) -> LamportRevision {
  LamportRevision(counter: counter, originDeviceID: device)
}
