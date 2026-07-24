import AppleAdapters
import Foundation
import Testing

@testable import AppRuntime

@Suite("Touch exchange state machine")
struct TouchExchangeStateMachineTests {
  private let localParticipantID = "local-player-0001"
  private let peerCard = PublicPetCardV1(
    petName: "Mochi",
    characterID: "pet.mochi",
    outfitID: "outfit.raincoat",
    backgroundID: "background.park",
    socialState: .walk
  )

  @Test func publicCardContainsOnlyVersionedGameFields() throws {
    let encoder = JSONEncoder()
    let data = try encoder.encode(peerCard)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(
      Set(object.keys)
        == [
          "schema_version",
          "pet_name",
          "character_id",
          "outfit_id",
          "background_id",
          "social_state",
        ]
    )
    for forbidden in ["health", "vitality", "theme", "mood", "sleep", "steps"] {
      #expect(object[forbidden] == nil)
    }
  }

  @Test func futurePublicCardSchemasFailClosed() throws {
    let data = Data(
      """
      {
        "schema_version": "public_pet_card_v2",
        "pet_name": "Peer",
        "character_id": "pet.peer"
      }
      """.utf8
    )
    #expect(throws: PublicPetCardError.unsupportedSchemaVersion("public_pet_card_v2")) {
      try JSONDecoder().decode(PublicPetCardV1.self, from: data)
    }
  }

  @Test func incomingCardsRejectPrivateOrUnknownFields() {
    let data = Data(
      """
      {
        "schema_version": "public_pet_card_v1",
        "pet_name": "Peer",
        "character_id": "pet.peer",
        "vitality": 80
      }
      """.utf8
    )
    #expect(throws: PublicPetCardError.disallowedField("vitality")) {
      try JSONDecoder().decode(PublicPetCardV1.self, from: data)
    }
  }

  @Test func incomingCardsRequireAnExplicitSocialState() {
    let data = Data(
      """
      {
        "schema_version": "public_pet_card_v1",
        "pet_name": "Peer",
        "character_id": "pet.peer"
      }
      """.utf8
    )
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(PublicPetCardV1.self, from: data)
    }
  }

  @Test func nilStaleFarAndGappedSamplesResetTheStreak() throws {
    let base = Date(timeIntervalSince1970: 1_000)
    var machine = EncounterStateMachine(
      configuration: ProximityStabilityPolicy(
        maximumDistanceMeters: 0.15,
        requiredConsecutiveSamples: 3,
        maximumSampleAge: 1,
        maximumGapBetweenSamples: 0.5
      )
    )
    machine.startRendezvous(participantID: localParticipantID)
    try machine.didMatch(sessionID: "session")

    #expect(
      try !machine.recordMeasurement(
        NearbyMeasurement(distanceMeters: 0.1, capturedAt: base),
        now: base
      )
    )
    #expect(try !machine.recordMeasurement(nil, now: base.addingTimeInterval(0.1)))

    #expect(
      try !machine.recordMeasurement(
        NearbyMeasurement(distanceMeters: 0.1, capturedAt: base),
        now: base.addingTimeInterval(2)
      )
    )
    #expect(
      try !machine.recordMeasurement(
        NearbyMeasurement(
          distanceMeters: 0.4,
          capturedAt: base.addingTimeInterval(2.1)
        ),
        now: base.addingTimeInterval(2.1)
      )
    )

    #expect(
      try !machine.recordMeasurement(
        NearbyMeasurement(
          distanceMeters: 0.1,
          capturedAt: base.addingTimeInterval(3)
        ),
        now: base.addingTimeInterval(3)
      )
    )
    #expect(
      try !machine.recordMeasurement(
        NearbyMeasurement(
          distanceMeters: 0.1,
          capturedAt: base.addingTimeInterval(4)
        ),
        now: base.addingTimeInterval(4)
      )
    )
    #expect(
      try !machine.recordMeasurement(
        NearbyMeasurement(
          distanceMeters: 0.1,
          capturedAt: base.addingTimeInterval(4.2)
        ),
        now: base.addingTimeInterval(4.2)
      )
    )
    #expect(
      try machine.recordMeasurement(
        NearbyMeasurement(
          distanceMeters: 0.1,
          capturedAt: base.addingTimeInterval(4.4)
        ),
        now: base.addingTimeInterval(4.4)
      )
    )
    #expect(machine.state.proximitySatisfied)
  }

  @Test func completionRequiresBothConfirmationsAndIsIdempotent() throws {
    let now = Date(timeIntervalSince1970: 2_000)
    var machine = EncounterStateMachine(
      configuration: ProximityStabilityPolicy(requiredConsecutiveSamples: 1)
    )
    machine.startRendezvous(participantID: localParticipantID)
    try machine.didMatch(sessionID: "session", encounterID: "encounter")
    _ = try machine.recordMeasurement(
      NearbyMeasurement(distanceMeters: 0.1, capturedAt: now),
      now: now
    )
    try machine.showPreview(peerCard: peerCard)

    try machine.confirmLocal(now: now)
    try machine.confirmLocal(now: now.addingTimeInterval(1))
    #expect(machine.state.phase == .awaitingConfirmations)
    #expect(machine.state.localConfirmed)
    #expect(!machine.state.peerConfirmed)

    try machine.confirmPeer(now: now.addingTimeInterval(2))
    let completed = try #require(machine.state.encounter)
    #expect(machine.state.phase == .completed)
    #expect(completed.id == "encounter")
    #expect(completed.completedAt == now.addingTimeInterval(2))

    try machine.confirmPeer(now: now.addingTimeInterval(20))
    #expect(machine.state.encounter == completed)
  }

  @Test func completedEncounterAcceptsOnlyItsOwnTransferCue() throws {
    let now = Date(timeIntervalSince1970: 2_100)
    var machine = EncounterStateMachine(
      configuration: ProximityStabilityPolicy(requiredConsecutiveSamples: 1)
    )
    machine.startRendezvous(participantID: localParticipantID)
    try machine.didMatch(sessionID: "session", encounterID: "encounter")
    _ = try machine.recordMeasurement(
      NearbyMeasurement(distanceMeters: 0.1, capturedAt: now),
      now: now
    )
    try machine.showPreview(peerCard: peerCard)
    try machine.confirmLocal(now: now)
    try machine.confirmPeer(now: now)

    let cue = PetTransferAnimationCue(
      eventID: "encounter",
      role: .source,
      startsAt: now.addingTimeInterval(1.25),
      durationMilliseconds: 900
    )
    try machine.applyTransferAnimationCue(cue)
    #expect(machine.state.transferAnimationCue == cue)

    let wrongCue = PetTransferAnimationCue(
      eventID: "another-encounter",
      role: .destination,
      startsAt: now,
      durationMilliseconds: 900
    )
    #expect(throws: EncounterTransitionError.transferAnimationIdentityMismatch) {
      try machine.applyTransferAnimationCue(wrongCue)
    }
    #expect(machine.state.transferAnimationCue == cue)
  }

  @Test func anUnverifiedCandidateCanReturnToAutomaticDiscovery() throws {
    var machine = EncounterStateMachine()
    machine.startRendezvous(participantID: localParticipantID)
    try machine.didMatch(sessionID: "session", encounterID: "first-candidate")

    try machine.didLoseCandidate()

    #expect(machine.state.phase == .rendezvous)
    #expect(machine.state.sessionID == "session")
    #expect(machine.state.encounterID == nil)
    #expect(machine.state.peerCard == nil)
    #expect(!machine.state.proximitySatisfied)

    try machine.didMatch(sessionID: "session", encounterID: "second-candidate")
    #expect(machine.state.phase == .ranging)
    #expect(machine.state.encounterID == "second-candidate")
  }

  @Test func replacingACandidateDiscardsPreviewAndConsentState() throws {
    let now = Date(timeIntervalSince1970: 2_250)
    var machine = EncounterStateMachine(
      configuration: ProximityStabilityPolicy(requiredConsecutiveSamples: 1)
    )
    machine.startRendezvous(participantID: localParticipantID)
    try machine.didMatch(sessionID: "session", encounterID: "old-candidate")
    _ = try machine.recordMeasurement(
      NearbyMeasurement(distanceMeters: 0.1, capturedAt: now),
      now: now
    )
    try machine.showPreview(peerCard: peerCard)
    try machine.confirmLocal(now: now)

    try machine.didMatch(sessionID: "session", encounterID: "new-candidate")

    #expect(machine.state.phase == .ranging)
    #expect(machine.state.encounterID == "new-candidate")
    #expect(machine.state.peerCard == nil)
    #expect(!machine.state.proximitySatisfied)
    #expect(!machine.state.localConfirmed)
    #expect(!machine.state.peerConfirmed)
  }

  @Test func peerMayConfirmFirstButCannotCompleteWithoutLocalConsent() throws {
    let now = Date(timeIntervalSince1970: 2_500)
    var machine = EncounterStateMachine(
      configuration: ProximityStabilityPolicy(requiredConsecutiveSamples: 1)
    )
    machine.startRendezvous(participantID: localParticipantID)
    try machine.didMatch(sessionID: "session", encounterID: "encounter")
    _ = try machine.recordMeasurement(
      NearbyMeasurement(distanceMeters: 0.1, capturedAt: now),
      now: now
    )
    try machine.showPreview(peerCard: peerCard)

    try machine.confirmPeer(now: now)
    #expect(machine.state.phase == .awaitingConfirmations)
    #expect(!machine.state.localConfirmed)
    #expect(machine.state.encounter == nil)

    try machine.confirmLocal(now: now.addingTimeInterval(1))
    #expect(machine.state.phase == .completed)
    #expect(machine.state.encounter?.completedAt == now.addingTimeInterval(1))
  }
}

@Suite("Touch exchange coordinator")
struct TouchExchangeCoordinatorTests {
  @Test func cancellingBeforeStartIsIdempotentAndDoesNotCallGateway() async throws {
    let nearby = MockNearbyRangingClient(
      capability: .unavailable(reason: "Precise ranging is unavailable")
    )
    let rendezvous = DeterministicMockSocialRendezvousClient()
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous
    )

    let firstCancellation = try await coordinator.cancel()
    let repeatedCancellation = try await coordinator.cancel()

    #expect(firstCancellation.phase == .cancelled)
    #expect(repeatedCancellation.phase == .cancelled)
    #expect(await rendezvous.callLog.isEmpty)
  }

  @Test func cancellationDuringInitialStopPreventsAStaleStart() async throws {
    let nearby = DelayedInitialStopNearbyRangingClient()
    let rendezvous = DeterministicMockSocialRendezvousClient()
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous
    )
    let startTask = Task {
      try await coordinator.start(
        participantID: "local-player-0001",
        publicCard: PublicPetCardV1(
          petName: "Local",
          characterID: "pet.local",
          socialState: .greeting
        ),
        joinRequestID: "join-request-initial-stop-race"
      )
    }

    await nearby.waitUntilInitialStopBegins()
    let cancelled = try await coordinator.cancel()
    await nearby.releaseInitialStop()
    let staleStartResult = try await startTask.value

    #expect(cancelled.phase == .cancelled)
    #expect(staleStartResult.phase == .cancelled)
    #expect(await coordinator.state.phase == .cancelled)
    #expect(await rendezvous.callLog.isEmpty)
  }

  @Test func deterministicSimulatorFlowCompletesOnce() async throws {
    let localCard = PublicPetCardV1(
      petName: "Local",
      characterID: "pet.local",
      socialState: .greeting
    )
    let nearby = MockNearbyRangingClient(capability: .preciseDistance)
    let rendezvous = DeterministicMockSocialRendezvousClient()
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous,
      proximityPolicy: ProximityStabilityPolicy(requiredConsecutiveSamples: 2)
    )
    let base = Date(timeIntervalSince1970: 3_000)

    var state = try await coordinator.start(
      participantID: "local-player-0001",
      publicCard: localCard,
      joinRequestID: "join-request-local-1"
    )
    #expect(state.phase == .rendezvous)

    state = try await coordinator.refresh(now: base)
    #expect(state.phase == .ranging)

    state = try await coordinator.processMeasurement(
      NearbyMeasurement(distanceMeters: 0.1, capturedAt: base),
      now: base
    )
    #expect(state.phase == .ranging)
    state = try await coordinator.processMeasurement(
      NearbyMeasurement(
        distanceMeters: 0.1,
        capturedAt: base.addingTimeInterval(0.2)
      ),
      now: base.addingTimeInterval(0.2)
    )
    #expect(state.phase == .preview)
    #expect(state.peerCard?.petName == "Nearby Friend")

    state = try await coordinator.confirm(now: base.addingTimeInterval(1))
    #expect(state.phase == .completed)
    state = try await coordinator.confirm(now: base.addingTimeInterval(2))
    #expect(state.phase == .completed)
    #expect(await rendezvous.callLog.filter { $0 == "confirm" }.count == 1)
  }

  @Test func coordinatorProjectsTheConfirmedCueIntoTheLocalWatchClock() async throws {
    let start = Date(timeIntervalSince1970: 3_250)
    let serverTime = start.addingTimeInterval(-1.25)
    let localReceivedAt = start.addingTimeInterval(120)
    let cue = PetTransferAnimationCue(
      eventID: "mock-encounter-1",
      role: .destination,
      startsAt: start,
      durationMilliseconds: 900
    )
    let nearby = MockNearbyRangingClient(capability: .preciseDistance)
    let rendezvous = DeterministicMockSocialRendezvousClient(
      configuration: .init(
        serverTime: serverTime,
        transferRole: .destination,
        transferAnimation: cue
      )
    )
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous,
      proximityPolicy: ProximityStabilityPolicy(requiredConsecutiveSamples: 1),
      clock: { localReceivedAt }
    )

    _ = try await coordinator.start(
      participantID: "local-player-0001",
      publicCard: PublicPetCardV1(
        petName: "Local",
        characterID: "penguin",
        socialState: .greeting
      ),
      joinRequestID: "join-request-transfer-cue"
    )
    _ = try await coordinator.refresh(now: start.addingTimeInterval(-2))
    _ = try await coordinator.processMeasurement(
      NearbyMeasurement(
        distanceMeters: 0.08,
        capturedAt: start.addingTimeInterval(-1)
      ),
      now: start.addingTimeInterval(-1)
    )
    let completed = try await coordinator.confirm(
      now: start.addingTimeInterval(-0.5)
    )

    #expect(completed.phase == .completed)
    #expect(completed.transferRole == .destination)
    #expect(completed.transferAnimationCue?.eventID == cue.eventID)
    #expect(completed.transferAnimationCue?.role == .destination)
    #expect(
      completed.transferAnimationCue?.startsAt
        == localReceivedAt.addingTimeInterval(1.25)
    )
  }

  @Test func sameServerCueHasTheSameRemainingDelayOnOffsetWatchClocks() {
    let serverTime = Date(timeIntervalSince1970: 10_000)
    let serverStart = serverTime.addingTimeInterval(1.25)
    let eventID = "0123456789abcdef0123456789abcdef"
    let watchAReceivedAt = serverTime.addingTimeInterval(120)
    let watchBReceivedAt = serverTime.addingTimeInterval(-75)
    let common = (
      sessionID: "session",
      expiresAt: serverTime.addingTimeInterval(30),
      encounterID: eventID,
      encounterNonce: "encounter-nonce"
    )
    let source = RendezvousSessionSnapshot(
      sessionID: common.sessionID,
      status: .confirmed,
      serverTime: serverTime,
      expiresAt: common.expiresAt,
      encounterID: common.encounterID,
      encounterNonce: common.encounterNonce,
      transferRole: .source,
      transferAnimation: PetTransferAnimationCue(
        eventID: eventID,
        role: .source,
        startsAt: serverStart,
        durationMilliseconds: 900
      )
    )
    let destination = RendezvousSessionSnapshot(
      sessionID: common.sessionID,
      status: .confirmed,
      serverTime: serverTime,
      expiresAt: common.expiresAt,
      encounterID: common.encounterID,
      encounterNonce: common.encounterNonce,
      transferRole: .destination,
      transferAnimation: PetTransferAnimationCue(
        eventID: eventID,
        role: .destination,
        startsAt: serverStart,
        durationMilliseconds: 900
      )
    )

    let sourceCue = source.localizedTransferAnimation(receivedAt: watchAReceivedAt)
    let destinationCue = destination.localizedTransferAnimation(
      receivedAt: watchBReceivedAt
    )
    #expect(sourceCue?.eventID == destinationCue?.eventID)
    #expect(sourceCue?.role == .source)
    #expect(destinationCue?.role == .destination)
    #expect(sourceCue?.startsAt.timeIntervalSince(watchAReceivedAt) == 1.25)
    #expect(destinationCue?.startsAt.timeIntervalSince(watchBReceivedAt) == 1.25)
  }

  @Test func repeatsProximityReadyUntilThePeerOverlaps() async throws {
    let localCard = PublicPetCardV1(
      petName: "Local",
      characterID: "pet.local",
      socialState: .greeting
    )
    let nearby = MockNearbyRangingClient(capability: .preciseDistance)
    let rendezvous = DeterministicMockSocialRendezvousClient(
      configuration: .init(peerReadyAfterMarkCount: 2)
    )
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous,
      proximityPolicy: ProximityStabilityPolicy(requiredConsecutiveSamples: 1)
    )
    let base = Date(timeIntervalSince1970: 3_500)

    _ = try await coordinator.start(
      participantID: "local-player-0001",
      publicCard: localCard,
      joinRequestID: "join-request-local-2"
    )
    _ = try await coordinator.refresh(now: base)
    var state = try await coordinator.processMeasurement(
      NearbyMeasurement(distanceMeters: 0.1, capturedAt: base),
      now: base
    )
    #expect(state.phase == .ranging)

    state = try await coordinator.processMeasurement(
      NearbyMeasurement(
        distanceMeters: 0.1,
        capturedAt: base.addingTimeInterval(0.2)
      ),
      now: base.addingTimeInterval(0.2)
    )
    #expect(state.phase == .preview)
    #expect(await rendezvous.callLog.filter { $0 == "proximity-ready" }.count == 2)
  }

  @Test func localConsentCompletesWhenThePeerConfirmedFirst() async throws {
    let localCard = PublicPetCardV1(
      petName: "Local",
      characterID: "pet.local",
      socialState: .greeting
    )
    let nearby = MockNearbyRangingClient(capability: .preciseDistance)
    let rendezvous = DeterministicMockSocialRendezvousClient(
      configuration: .init(peerConfirmsBeforeLocal: true)
    )
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous,
      proximityPolicy: ProximityStabilityPolicy(requiredConsecutiveSamples: 1)
    )
    let base = Date(timeIntervalSince1970: 3_800)

    _ = try await coordinator.start(
      participantID: "local-player-0001",
      publicCard: localCard,
      joinRequestID: "join-request-local-3"
    )
    _ = try await coordinator.refresh(now: base)
    _ = try await coordinator.processMeasurement(
      NearbyMeasurement(distanceMeters: 0.1, capturedAt: base),
      now: base
    )
    var state = try await coordinator.refresh(now: base.addingTimeInterval(0.5))
    #expect(state.phase == .awaitingConfirmations)
    #expect(state.peerConfirmed)
    #expect(!state.localConfirmed)

    state = try await coordinator.confirm(now: base.addingTimeInterval(1))
    #expect(state.phase == .completed)
    #expect(state.localConfirmed)
    #expect(state.peerConfirmed)
  }

  @Test func directCandidateReplacementResetsAndSwitchesRanging() async throws {
    let localCard = PublicPetCardV1(
      petName: "Local",
      characterID: "pet.local",
      socialState: .greeting
    )
    let nearby = MockNearbyRangingClient(capability: .preciseDistance)
    let rendezvous = RotatingMockSocialRendezvousClient()
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous
    )

    var state = try await coordinator.start(
      participantID: "local-player-0001",
      publicCard: localCard,
      joinRequestID: "join-request-rotation-1"
    )
    #expect(state.phase == .rendezvous)

    state = try await coordinator.refresh()
    #expect(state.phase == .ranging)
    #expect(await nearby.peerToken?.encodedValue == Data([0x02]))
    let oldMeasurement = NearbyMeasurement(distanceMeters: 0.08, capturedAt: Date())
    await nearby.emit(oldMeasurement)
    #expect(await nearby.latestMeasurement() == oldMeasurement)

    state = try await coordinator.refresh()
    #expect(state.phase == .ranging)
    #expect(state.encounterID == "replacement-encounter")
    #expect(!state.proximitySatisfied)
    #expect(await nearby.peerToken?.encodedValue == Data([0x03]))
    #expect(await nearby.latestMeasurement() == nil)
  }

  @Test func lateOldCandidateResponseCannotReleaseAPreview() async throws {
    let localCard = PublicPetCardV1(
      petName: "Local",
      characterID: "pet.local",
      socialState: .greeting
    )
    let nearby = MockNearbyRangingClient(capability: .preciseDistance)
    let rendezvous = DelayedReplacementRendezvousClient()
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous,
      proximityPolicy: ProximityStabilityPolicy(requiredConsecutiveSamples: 1)
    )
    let now = Date(timeIntervalSince1970: 4_000)

    _ = try await coordinator.start(
      participantID: "local-player-0001",
      publicCard: localCard,
      joinRequestID: "join-request-generation-1"
    )
    _ = try await coordinator.refresh()

    let oldCandidateOperation = Task {
      try await coordinator.processMeasurement(
        NearbyMeasurement(distanceMeters: 0.08, capturedAt: now),
        now: now
      )
    }
    await rendezvous.waitUntilMarkStarted()

    let replaced = try await coordinator.refresh()
    #expect(replaced.phase == .ranging)
    #expect(replaced.encounterID == "new-encounter")
    #expect(!replaced.proximitySatisfied)
    #expect(await nearby.peerToken?.encodedValue == Data([0x03]))

    await rendezvous.releaseOldMark()
    let afterLateResponse = try await oldCandidateOperation.value
    #expect(afterLateResponse.phase == .ranging)
    #expect(afterLateResponse.encounterID == "new-encounter")
    #expect(afterLateResponse.peerCard == nil)
    #expect(!afterLateResponse.proximitySatisfied)
    #expect(await rendezvous.peerCardFetchCount == 0)
  }

  @Test func invalidPeerTokenStopsRangingButStillAllowsRemoteCancel() async throws {
    let nearby = MockNearbyRangingClient(capability: .preciseDistance)
    let rendezvous = DeterministicMockSocialRendezvousClient(
      configuration: .init(peerDiscoveryToken: Data())
    )
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous
    )

    _ = try await coordinator.start(
      participantID: "local-player-0001",
      publicCard: PublicPetCardV1(
        petName: "Local",
        characterID: "pet.local",
        socialState: .greeting
      ),
      joinRequestID: "join-request-invalid-token"
    )
    await #expect(throws: NearbyAdapterError.invalidPeerToken) {
      try await coordinator.refresh()
    }

    #expect(await coordinator.state.phase == .rendezvous)
    #expect(await nearby.peerToken == nil)
    #expect(await nearby.latestMeasurement() == nil)

    let cancelled = try await coordinator.cancel()
    #expect(cancelled.phase == .cancelled)
    _ = try await coordinator.cancel()
    #expect(await rendezvous.callLog.filter { $0 == "cancel" }.count == 1)
  }

  @Test func cancellationIsIdempotentForTheCurrentCandidate() async throws {
    let nearby = MockNearbyRangingClient(capability: .preciseDistance)
    let rendezvous = DeterministicMockSocialRendezvousClient()
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous
    )

    _ = try await coordinator.start(
      participantID: "local-player-0001",
      publicCard: PublicPetCardV1(
        petName: "Local",
        characterID: "pet.local",
        socialState: .greeting
      ),
      joinRequestID: "join-request-cancel-once"
    )
    _ = try await coordinator.refresh()

    #expect(try await coordinator.cancel().phase == .cancelled)
    #expect(try await coordinator.cancel().phase == .cancelled)
    #expect(await rendezvous.callLog.filter { $0 == "cancel" }.count == 1)
  }

  @Test func confirmedServerStateWinsAConcurrentConfirmCancelRace() async throws {
    let nearby = MockNearbyRangingClient(capability: .preciseDistance)
    let rendezvous = ConfirmCancelRaceRendezvousClient()
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous,
      proximityPolicy: ProximityStabilityPolicy(requiredConsecutiveSamples: 1)
    )
    let base = Date(timeIntervalSince1970: 4_500)

    _ = try await coordinator.start(
      participantID: "local-player-0001",
      publicCard: PublicPetCardV1(
        petName: "Local",
        characterID: "pet.local",
        socialState: .greeting
      ),
      joinRequestID: "join-request-confirm-cancel-race"
    )
    _ = try await coordinator.refresh()
    let preview = try await coordinator.processMeasurement(
      NearbyMeasurement(distanceMeters: 0.08, capturedAt: base),
      now: base
    )
    #expect(preview.phase == .preview)

    let delayedConfirm = Task {
      try await coordinator.confirm(now: base.addingTimeInterval(1))
    }
    await rendezvous.waitUntilConfirmReachedServer()

    let cancellationResult = try await coordinator.cancel(
      now: base.addingTimeInterval(2)
    )
    #expect(cancellationResult.phase == .completed)
    #expect(cancellationResult.encounterID == "race-encounter")
    #expect(cancellationResult.encounter?.id == "race-encounter")
    #expect(cancellationResult.encounter?.peerCard.petName == "Race Peer")
    #expect(cancellationResult.encounter?.completedAt == base.addingTimeInterval(2))

    await rendezvous.releaseConfirmResponse()
    let afterDelayedConfirm = try await delayedConfirm.value
    #expect(afterDelayedConfirm == cancellationResult)
    #expect(await rendezvous.cancelCount == 1)
    #expect(await rendezvous.statusCount == 2)
  }

  @Test func staleCancelAdoptsReplacementAndRetriesCurrentGeneration() async throws {
    let nearby = MockNearbyRangingClient(capability: .preciseDistance)
    let rendezvous = RotatingCancelRendezvousClient()
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous
    )

    _ = try await coordinator.start(
      participantID: "local-player-0001",
      publicCard: PublicPetCardV1(
        petName: "Local",
        characterID: "pet.local",
        socialState: .greeting
      ),
      joinRequestID: "join-request-stale-cancel"
    )
    let matched = try await coordinator.refresh()
    #expect(matched.encounterID == "cancel-old-encounter")

    await #expect(throws: SocialRendezvousError.server(statusCode: 503)) {
      try await coordinator.cancel()
    }
    #expect(await coordinator.state.phase == .rendezvous)

    let result = try await coordinator.cancel()

    #expect(result.phase == .cancelled)
    #expect(await nearby.peerToken == nil)
    #expect(
      await rendezvous.cancelledIdentities
        == [
          RendezvousEncounterIdentity(
            id: "cancel-old-encounter",
            nonce: "cancel-old-nonce"
          ),
          RendezvousEncounterIdentity(
            id: "cancel-new-encounter",
            nonce: "cancel-new-nonce"
          ),
          RendezvousEncounterIdentity(
            id: "cancel-new-encounter",
            nonce: "cancel-new-nonce"
          ),
        ]
    )
    #expect(await rendezvous.statusCount == 2)
  }

  @Test func cancelRecoversAnAcceptedCreateWhoseResponseWasLost() async throws {
    let nearby = MockNearbyRangingClient(capability: .preciseDistance)
    let rendezvous = LostCreateResponseRendezvousClient()
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous
    )
    let card = PublicPetCardV1(
      petName: "Local",
      characterID: "pet.local",
      socialState: .greeting
    )

    let start = Task {
      try await coordinator.start(
        participantID: "local-player-0001",
        publicCard: card,
        joinRequestID: "join-request-lost-create-response"
      )
    }
    await rendezvous.waitUntilFirstCreateWasAccepted()

    let cancelled = try await coordinator.cancel()
    #expect(cancelled.phase == .cancelled)
    let createRequests = await rendezvous.createRequests
    #expect(createRequests.count == 2)
    #expect(createRequests[0] == createRequests[1])
    #expect(await rendezvous.cancelCount == 1)

    await rendezvous.releaseLostCreateResponse()
    let staleStartResult = try await start.value
    #expect(staleStartResult.phase == .cancelled)
    #expect(await coordinator.state.phase == .cancelled)
  }

  @Test func candidate409ReconcilesReadyCardAndConfirmRotations() async throws {
    let base = Date(timeIntervalSince1970: 5_000)

    do {
      let nearby = MockNearbyRangingClient(capability: .preciseDistance)
      let rendezvous = CandidateConflictRendezvousClient(mode: .readyRotates)
      let coordinator = TouchExchangeCoordinator(
        rangingClient: nearby,
        rendezvousClient: rendezvous,
        proximityPolicy: ProximityStabilityPolicy(requiredConsecutiveSamples: 1)
      )
      try await startConflictCoordinator(coordinator)
      _ = try await coordinator.refresh()

      let state = try await coordinator.processMeasurement(
        NearbyMeasurement(distanceMeters: 0.08, capturedAt: base),
        now: base
      )
      #expect(state.phase == .ranging)
      #expect(state.encounterID == "conflict-new-encounter")
      #expect(await nearby.peerToken?.encodedValue == Data([0x03]))
    }

    do {
      let nearby = MockNearbyRangingClient(capability: .preciseDistance)
      let rendezvous = CandidateConflictRendezvousClient(mode: .cardReturnsWaiting)
      let coordinator = TouchExchangeCoordinator(
        rangingClient: nearby,
        rendezvousClient: rendezvous,
        proximityPolicy: ProximityStabilityPolicy(requiredConsecutiveSamples: 1)
      )
      try await startConflictCoordinator(coordinator)
      _ = try await coordinator.refresh()

      let state = try await coordinator.processMeasurement(
        NearbyMeasurement(distanceMeters: 0.08, capturedAt: base),
        now: base
      )
      #expect(state.phase == .rendezvous)
      #expect(state.encounterID == nil)
      #expect(await nearby.peerToken == nil)
    }

    do {
      let nearby = MockNearbyRangingClient(capability: .preciseDistance)
      let rendezvous = CandidateConflictRendezvousClient(mode: .confirmRotates)
      let coordinator = TouchExchangeCoordinator(
        rangingClient: nearby,
        rendezvousClient: rendezvous,
        proximityPolicy: ProximityStabilityPolicy(requiredConsecutiveSamples: 1)
      )
      try await startConflictCoordinator(coordinator)
      _ = try await coordinator.refresh()
      _ = try await coordinator.processMeasurement(
        NearbyMeasurement(distanceMeters: 0.08, capturedAt: base),
        now: base
      )

      let state = try await coordinator.confirm(now: base.addingTimeInterval(1))
      #expect(state.phase == .ranging)
      #expect(state.encounterID == "conflict-new-encounter")
      #expect(!state.localConfirmed)
      #expect(await nearby.peerToken?.encodedValue == Data([0x03]))
    }
  }

  @Test func candidate409StillThrowsForTheCurrentGeneration() async throws {
    let base = Date(timeIntervalSince1970: 5_500)
    let nearby = MockNearbyRangingClient(capability: .preciseDistance)
    let rendezvous = CandidateConflictRendezvousClient(mode: .confirmSameGeneration)
    let coordinator = TouchExchangeCoordinator(
      rangingClient: nearby,
      rendezvousClient: rendezvous,
      proximityPolicy: ProximityStabilityPolicy(requiredConsecutiveSamples: 1)
    )
    try await startConflictCoordinator(coordinator)
    _ = try await coordinator.refresh()
    _ = try await coordinator.processMeasurement(
      NearbyMeasurement(distanceMeters: 0.08, capturedAt: base),
      now: base
    )

    await #expect(throws: SocialRendezvousError.server(statusCode: 409)) {
      try await coordinator.confirm(now: base.addingTimeInterval(1))
    }
    #expect(await coordinator.state.encounterID == "conflict-old-encounter")
  }

  private func startConflictCoordinator(
    _ coordinator: TouchExchangeCoordinator
  ) async throws {
    _ = try await coordinator.start(
      participantID: "local-player-0001",
      publicCard: PublicPetCardV1(
        petName: "Local",
        characterID: "pet.local",
        socialState: .greeting
      ),
      joinRequestID: "join-request-candidate-conflict"
    )
  }
}

private actor DelayedInitialStopNearbyRangingClient: NearbyRangingClient {
  private var stopCount = 0
  private var initialStopStarted = false
  private var initialStopWaiters: [CheckedContinuation<Void, Never>] = []
  private var initialStopRelease: CheckedContinuation<Void, Never>?

  func capability() -> NearbyCapability { .preciseDistance }

  func prepareLocalToken() -> NearbyDiscoveryToken {
    NearbyDiscoveryToken(encodedValue: Data([0x01]))
  }

  func beginRanging(peerToken: NearbyDiscoveryToken) {}

  func latestMeasurement() -> NearbyMeasurement? { nil }

  nonisolated func events() -> AsyncStream<NearbyRangingEvent> {
    AsyncStream { continuation in
      continuation.finish()
    }
  }

  func stop() async {
    stopCount += 1
    guard stopCount == 1 else { return }
    initialStopStarted = true
    let waiters = initialStopWaiters
    initialStopWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      initialStopRelease = continuation
    }
  }

  func waitUntilInitialStopBegins() async {
    guard !initialStopStarted else { return }
    await withCheckedContinuation { continuation in
      initialStopWaiters.append(continuation)
    }
  }

  func releaseInitialStop() {
    initialStopRelease?.resume()
    initialStopRelease = nil
  }
}

@Suite("Social rendezvous HTTP contract", .serialized)
struct SocialRendezvousHTTPTests {
  @Test func rejectsPartialEncounterCredentialsAndSnapshots() throws {
    let sessionCredentials = RendezvousCredentials(
      sessionID: "session-1",
      participantID: "local-player-0001",
      nonce: "nonce-1"
    )
    #expect(throws: SocialRendezvousError.missingCredentials) {
      _ = try RendezvousCandidateRequest(credentials: sessionCredentials)
    }

    let incompleteCredentials = RendezvousCredentials(
      sessionID: "session-1",
      participantID: "local-player-0001",
      nonce: "nonce-1",
      encounterID: "encounter-1"
    )
    #expect(throws: SocialRendezvousError.incompleteEncounterIdentity) {
      _ = try RendezvousCancelRequest(credentials: incompleteCredentials)
    }

    let incompleteSnapshot = RendezvousSessionSnapshot(
      sessionID: "session-1",
      status: .matched,
      expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
      encounterID: "encounter-1"
    )
    #expect(throws: SocialRendezvousError.incompleteEncounterIdentity) {
      _ = try incompleteSnapshot.encounterIdentity
    }

    let currentCredentials = RendezvousCredentials(
      sessionID: "session-1",
      participantID: "local-player-0001",
      nonce: "nonce-1",
      encounterID: "encounter-1",
      encounterNonce: "encounter-nonce-1"
    )
    let statusBody = try #require(
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(
          RendezvousAuthenticatedRequest(credentials: currentCredentials)
        )
      ) as? [String: Any]
    )
    #expect(Set(statusBody.keys) == ["participant_id", "nonce"])
  }

  @Test func decodesGatewayV1ResponseFixtures() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let join = try decoder.decode(
      RendezvousSessionSnapshot.self,
      from: Data(
        """
        {
          "session_id": "session-1",
          "nonce": "nonce-1",
          "status": "waiting",
          "expires_at": "2026-07-23T12:03:00Z",
          "self_proximity_ready": false,
          "peer_proximity_ready": false,
          "proximity_verified": false,
          "proximity_verified_at": null,
          "self_preview_released": false,
          "peer_preview_released": false,
          "self_confirmed": false,
          "peer_confirmed": false
        }
        """.utf8
      )
    )
    #expect(join.status == .waitingForPeer)
    #expect(join.nonce == "nonce-1")

    let status = try decoder.decode(
      RendezvousSessionSnapshot.self,
      from: Data(
        """
        {
          "session_id": "session-1",
          "status": "matched",
          "expires_at": "2026-07-23T12:03:00Z",
          "encounter_id": "encounter-1",
          "encounter_nonce": "encounter-nonce-1",
          "transfer_role": "source",
          "peer_discovery_token": "Ag==",
          "self_proximity_ready": true,
          "peer_proximity_ready": true,
          "proximity_verified": true,
          "proximity_verified_at": "2026-07-23T12:00:05.123456Z",
          "self_preview_released": false,
          "peer_preview_released": false,
          "self_confirmed": false,
          "peer_confirmed": false
        }
        """.utf8
      )
    )
    #expect(status.nonce == nil)
    #expect(status.peerDiscoveryToken == Data([0x02]))
    #expect(status.transferRole == .source)

    let confirmed = try decoder.decode(
      RendezvousSessionSnapshot.self,
      from: Data(
        """
        {
          "session_id": "session-1",
          "status": "confirmed",
          "server_time": "2026-07-23T12:00:07Z",
          "expires_at": "2026-07-23T12:03:00Z",
          "encounter_id": "encounter-1",
          "encounter_nonce": "encounter-nonce-1",
          "transfer_role": "source",
          "self_proximity_ready": true,
          "peer_proximity_ready": true,
          "proximity_verified": true,
          "proximity_verified_at": "2026-07-23T12:00:05.123456Z",
          "self_preview_released": true,
          "peer_preview_released": true,
          "self_confirmed": true,
          "peer_confirmed": true,
          "transfer_animation": {
            "schema_version": "pet_transfer_animation_v1",
            "event_id": "0123456789abcdef0123456789abcdef",
            "role": "source",
            "starts_at": "2026-07-23T12:00:08Z",
            "duration_ms": 900
          }
        }
        """.utf8
      )
    )
    #expect(confirmed.status == .confirmed)
    #expect(confirmed.serverTime == Date(timeIntervalSince1970: 1_784_808_007))
    #expect(confirmed.transferRole == .source)
    #expect(confirmed.transferAnimation?.role == .source)
    #expect(confirmed.transferAnimation?.durationMilliseconds == 900)
    #expect(confirmed.transferAnimation?.isSupported == true)

    let peer = try decoder.decode(
      PeerCardSnapshot.self,
      from: Data(
        """
        {
          "encounter_id": "encounter-1",
          "encounter_nonce": "encounter-nonce-1",
          "public_card": {
            "schema_version": "public_pet_card_v1",
            "pet_name": "Peer",
            "character_id": "pet.peer",
            "social_state": "greeting"
          }
        }
        """.utf8
      )
    )
    #expect(peer.card.petName == "Peer")
    #expect(peer.card.socialState == .greeting)
  }

  @Test func usesExactPostRoutesAndCredentialBodiesWithoutSecrets() async throws {
    let fixedNow = Date(timeIntervalSince1970: 1_774_224_000)
    RendezvousURLProtocolStub.reset(now: fixedNow)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RendezvousURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let client = try HTTPSocialRendezvousClient(
      baseURL: try #require(URL(string: "https://social.example/api")),
      session: session,
      now: { fixedNow }
    )
    let card = PublicPetCardV1(
      petName: "Local",
      characterID: "pet.local",
      socialState: .greeting
    )
    let created = try await client.createSession(
      CreateRendezvousSessionRequest(
        participantID: "local-player-0001",
        discoveryToken: NearbyDiscoveryToken(encodedValue: Data([0x01, 0x02])),
        publicCard: card,
        joinRequestID: "join-request-local-1"
      )
    )
    #expect(created.status == .waitingForPeer)
    var credentials = RendezvousCredentials(
      sessionID: created.sessionID,
      participantID: "local-player-0001",
      nonce: try #require(created.nonce)
    )

    let status = try await client.status(credentials)
    #expect(status.nonce == nil)
    guard let statusIdentity = try status.encounterIdentity else {
      throw SocialRendezvousError.incompleteEncounterIdentity
    }
    credentials = credentials.replacingEncounter(with: statusIdentity)
    let proximity = try await client.markProximityReady(credentials)
    #expect(proximity.selfProximityReady == true)
    #expect(proximity.peerProximityReady == true)
    #expect(proximity.proximityVerified == true)
    let peer = try await client.fetchPeerCard(credentials)
    #expect(peer.card.socialState == .greeting)
    let confirmed = try await client.confirm(credentials)
    #expect(confirmed.status == .confirmed)
    #expect(confirmed.selfConfirmed == true)
    #expect(confirmed.peerConfirmed == true)
    _ = try await client.cancel(credentials)

    let requests = RendezvousURLProtocolStub.recordedRequests()
    #expect(requests.count == 6)
    #expect(requests.allSatisfy { $0.httpMethod == "POST" })
    #expect(
      requests.compactMap(\.url?.path)
        == [
          "/api/v1/sessions",
          "/api/v1/sessions/session-1/status",
          "/api/v1/sessions/session-1/proximity-ready",
          "/api/v1/sessions/session-1/peer-card",
          "/api/v1/sessions/session-1/confirm",
          "/api/v1/sessions/session-1/cancel",
        ]
    )
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })

    let createData = try #require(requests.first?.httpBody)
    let createBody = try #require(
      try JSONSerialization.jsonObject(
        with: createData
      ) as? [String: Any]
    )
    #expect(createBody["participant_id"] as? String == "local-player-0001")
    #expect(createBody["discovery_token"] as? String == "AQI=")
    #expect(createBody["public_card"] != nil)
    #expect(createBody["join_request_id"] as? String == "join-request-local-1")
    #expect(createBody["secret"] == nil)
    #expect(
      Set(createBody.keys)
        == ["participant_id", "discovery_token", "public_card", "join_request_id"]
    )

    let statusRequestData = try #require(requests[1].httpBody)
    let statusBody = try #require(
      try JSONSerialization.jsonObject(
        with: statusRequestData
      ) as? [String: Any]
    )
    #expect(Set(statusBody.keys) == ["participant_id", "nonce"])

    for request in requests.dropFirst(2) {
      let requestData = try #require(request.httpBody)
      let body = try #require(
        try JSONSerialization.jsonObject(
          with: requestData
        ) as? [String: Any]
      )
      #expect(
        Set(body.keys)
          == ["participant_id", "nonce", "encounter_id", "encounter_nonce"]
      )
      #expect(body["encounter_id"] as? String == "encounter-1")
      #expect(body["encounter_nonce"] as? String == "encounter-nonce-1")
    }
  }

  @Test func retriesCreateTransportFailureWithIdenticalBodyAndBoundedAttempts() async throws {
    let fixedNow = Date(timeIntervalSince1970: 1_774_224_000)
    CreateRetryURLProtocolStub.reset(
      now: fixedNow,
      transportFailures: 1
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CreateRetryURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = try HTTPSocialRendezvousClient(
      baseURL: try #require(URL(string: "https://social.example/api")),
      session: session,
      now: { fixedNow }
    )
    let request = CreateRendezvousSessionRequest(
      participantID: "local-player-retry-0001",
      discoveryToken: NearbyDiscoveryToken(encodedValue: Data([0x01, 0x02, 0x03])),
      publicCard: PublicPetCardV1(
        petName: "Retry Local",
        characterID: "pet.retry",
        socialState: .greeting
      ),
      joinRequestID: "join-request-transport-retry-1"
    )

    let created = try await client.createSession(request)

    #expect(created.sessionID == "retry-session-1")
    let successfulBodies = CreateRetryURLProtocolStub.recordedBodies()
    #expect(successfulBodies.count == 2)
    #expect(successfulBodies[0] == successfulBodies[1])
    let body = try #require(
      try JSONSerialization.jsonObject(
        with: successfulBodies[0]
      ) as? [String: Any]
    )
    #expect(body["participant_id"] as? String == "local-player-retry-0001")
    #expect(body["discovery_token"] as? String == "AQID")
    #expect(body["join_request_id"] as? String == "join-request-transport-retry-1")

    CreateRetryURLProtocolStub.reset(
      now: fixedNow,
      transportFailures: 10
    )
    await #expect(throws: URLError.self) {
      try await client.createSession(request)
    }
    #expect(CreateRetryURLProtocolStub.recordedBodies().count == 2)
  }

  @Test func createDoesNotRetryHTTPOrDecodingFailures() async throws {
    let fixedNow = Date(timeIntervalSince1970: 1_774_224_000)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CreateRetryURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = try HTTPSocialRendezvousClient(
      baseURL: try #require(URL(string: "https://social.example/api")),
      session: session,
      now: { fixedNow }
    )
    let request = CreateRendezvousSessionRequest(
      participantID: "local-player-retry-0002",
      discoveryToken: NearbyDiscoveryToken(encodedValue: Data([0x04])),
      publicCard: PublicPetCardV1(
        petName: "Retry Local",
        characterID: "pet.retry",
        socialState: .greeting
      ),
      joinRequestID: "join-request-no-retry-1"
    )

    CreateRetryURLProtocolStub.reset(
      now: fixedNow,
      transportFailures: 0,
      statusCode: 422
    )
    await #expect(throws: SocialRendezvousError.server(statusCode: 422)) {
      try await client.createSession(request)
    }
    #expect(CreateRetryURLProtocolStub.recordedBodies().count == 1)

    CreateRetryURLProtocolStub.reset(
      now: fixedNow,
      transportFailures: 0,
      malformedResponse: true
    )
    await #expect(throws: DecodingError.self) {
      try await client.createSession(request)
    }
    #expect(CreateRetryURLProtocolStub.recordedBodies().count == 1)
  }

  @Test func rejectsInsecureBaseURLs() {
    #expect(throws: SocialRendezvousError.insecureBaseURL) {
      _ = try HTTPSocialRendezvousClient(
        baseURL: #require(URL(string: "http://social.example"))
      )
    }
  }

  @Test func rejectsInvalidJoinMetadataBeforeNetworkAccess() async throws {
    let client = try HTTPSocialRendezvousClient(
      baseURL: #require(URL(string: "https://social.example"))
    )
    let card = PublicPetCardV1(
      petName: "Local",
      characterID: "pet.local",
      socialState: .greeting
    )
    let token = NearbyDiscoveryToken(encodedValue: Data([0x01]))

    await #expect(throws: SocialRendezvousError.invalidJoinRequestID) {
      try await client.createSession(
        CreateRendezvousSessionRequest(
          participantID: "local-player-0001",
          discoveryToken: token,
          publicCard: card,
          joinRequestID: ""
        )
      )
    }
  }
}

private final class CreateRetryURLProtocolStub: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) private static var bodies: [Data] = []
  nonisolated(unsafe) private static var responseNow = Date()
  nonisolated(unsafe) private static var failuresRemaining = 0
  nonisolated(unsafe) private static var responseStatusCode = 200
  nonisolated(unsafe) private static var returnsMalformedResponse = false
  private static let lock = NSLock()

  static func reset(
    now: Date,
    transportFailures: Int,
    statusCode: Int = 200,
    malformedResponse: Bool = false
  ) {
    lock.withLock {
      bodies = []
      responseNow = now
      failuresRemaining = max(0, transportFailures)
      responseStatusCode = statusCode
      returnsMalformedResponse = malformedResponse
    }
  }

  static func recordedBodies() -> [Data] {
    lock.withLock { bodies }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    do {
      let body = try Self.captureBody(in: request)
      let behavior = Self.lock.withLock {
        Self.bodies.append(body)
        let shouldFail = Self.failuresRemaining > 0
        if shouldFail {
          Self.failuresRemaining -= 1
        }
        return (
          shouldFail: shouldFail,
          now: Self.responseNow,
          statusCode: Self.responseStatusCode,
          malformed: Self.returnsMalformedResponse
        )
      }
      if behavior.shouldFail {
        client?.urlProtocol(
          self,
          didFailWithError: URLError(.networkConnectionLost)
        )
        return
      }

      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: behavior.statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      let data =
        if behavior.malformed {
          Data("{not-json".utf8)
        } else {
          try JSONSerialization.data(
            withJSONObject: [
              "session_id": "retry-session-1",
              "nonce": "retry-nonce-1",
              "status": "waiting",
              "expires_at": ISO8601DateFormatter().string(
                from: behavior.now.addingTimeInterval(180)
              ),
            ]
          )
        }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}

  private static func captureBody(in request: URLRequest) throws -> Data {
    if let body = request.httpBody {
      return body
    }
    guard let stream = request.httpBodyStream else {
      return Data()
    }
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 {
        throw stream.streamError ?? SocialRendezvousError.invalidHTTPResponse
      }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

private final class RendezvousURLProtocolStub: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) private static var requests: [URLRequest] = []
  nonisolated(unsafe) private static var responseNow = Date()
  private static let lock = NSLock()

  static func reset(now: Date) {
    lock.withLock {
      requests = []
      responseNow = now
    }
  }

  static func recordedRequests() -> [URLRequest] {
    lock.withLock { requests }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    do {
      let capturedRequest = try Self.captureBody(in: request)
      let now = Self.lock.withLock {
        Self.requests.append(capturedRequest)
        return Self.responseNow
      }
      let data = try Self.responseData(for: capturedRequest, now: now)
      let response = HTTPURLResponse(
        url: try #require(capturedRequest.url),
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}

  private static func captureBody(in request: URLRequest) throws -> URLRequest {
    guard request.httpBody == nil, let stream = request.httpBodyStream else {
      return request
    }
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 {
        throw stream.streamError ?? SocialRendezvousError.invalidHTTPResponse
      }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    var captured = request
    captured.httpBodyStream = nil
    captured.httpBody = data
    return captured
  }

  private static func responseData(for request: URLRequest, now: Date) throws -> Data {
    let path = try #require(request.url?.path)
    if path.hasSuffix("/peer-card") {
      return try JSONSerialization.data(
        withJSONObject: [
          "encounter_id": "encounter-1",
          "encounter_nonce": "encounter-nonce-1",
          "public_card": [
            "schema_version": "public_pet_card_v1",
            "pet_name": "Peer",
            "character_id": "pet.peer",
            "social_state": "greeting",
          ],
        ]
      )
    }

    let status: String
    if path.hasSuffix("/confirm") {
      status = "confirmed"
    } else if path.hasSuffix("/cancel") {
      status = "cancelled"
    } else if path == "/api/v1/sessions" {
      status = "waiting"
    } else {
      status = "matched"
    }
    var response: [String: Any] = [
      "session_id": "session-1",
      "status": status,
      "expires_at": ISO8601DateFormatter().string(
        from: now.addingTimeInterval(180)
      ),
      "encounter_id": "encounter-1",
      "encounter_nonce": "encounter-nonce-1",
      "peer_discovery_token": "Ag==",
      "self_proximity_ready": path.contains("proximity-ready"),
      "peer_proximity_ready": path.contains("proximity-ready"),
      "proximity_verified": path.contains("proximity-ready"),
      "proximity_verified_at": path.contains("proximity-ready")
        ? ISO8601DateFormatter().string(from: now)
        : NSNull(),
      "self_preview_released": path.hasSuffix("/confirm"),
      "peer_preview_released": path.hasSuffix("/confirm"),
      "self_confirmed": path.hasSuffix("/confirm"),
      "peer_confirmed": path.hasSuffix("/confirm"),
    ]
    if path == "/api/v1/sessions" {
      response["nonce"] = "nonce-1"
      response.removeValue(forKey: "encounter_id")
      response.removeValue(forKey: "encounter_nonce")
      response.removeValue(forKey: "peer_discovery_token")
    }
    return try JSONSerialization.data(withJSONObject: response)
  }
}

private actor LostCreateResponseRendezvousClient: SocialRendezvousClient {
  private let sessionID = "lost-create-session"
  private let nonce = "lost-create-nonce"
  private var firstCreateAccepted = false
  private var firstCreateWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstCreateRelease: CheckedContinuation<Void, Never>?
  private(set) var createRequests: [CreateRendezvousSessionRequest] = []
  private(set) var cancelCount = 0

  func createSession(
    _ request: CreateRendezvousSessionRequest
  ) async throws -> RendezvousSessionSnapshot {
    try SocialRendezvousValidation.validate(request)
    createRequests.append(request)
    if createRequests.count == 1 {
      firstCreateAccepted = true
      let waiters = firstCreateWaiters
      firstCreateWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        firstCreateRelease = continuation
      }
      throw URLError(.networkConnectionLost)
    }
    return snapshot(status: .waitingForPeer, includeNonce: true)
  }

  func status(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validate(credentials)
    return snapshot(status: .waitingForPeer)
  }

  func markProximityReady(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    throw SocialRendezvousError.invalidMockCredentials
  }

  func fetchPeerCard(
    _ credentials: RendezvousCredentials
  ) throws -> PeerCardSnapshot {
    throw SocialRendezvousError.invalidMockCredentials
  }

  func confirm(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    throw SocialRendezvousError.invalidMockCredentials
  }

  func cancel(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validate(credentials)
    cancelCount += 1
    return snapshot(status: .cancelled)
  }

  func waitUntilFirstCreateWasAccepted() async {
    guard !firstCreateAccepted else { return }
    await withCheckedContinuation { continuation in
      firstCreateWaiters.append(continuation)
    }
  }

  func releaseLostCreateResponse() {
    firstCreateRelease?.resume()
    firstCreateRelease = nil
  }

  private func validate(_ credentials: RendezvousCredentials) throws {
    guard credentials.sessionID == sessionID,
      credentials.participantID == "local-player-0001",
      credentials.nonce == nonce,
      credentials.encounterIdentity == nil
    else {
      throw SocialRendezvousError.invalidMockCredentials
    }
  }

  private func snapshot(
    status: RendezvousStatus,
    includeNonce: Bool = false
  ) -> RendezvousSessionSnapshot {
    RendezvousSessionSnapshot(
      sessionID: sessionID,
      nonce: includeNonce ? nonce : nil,
      status: status,
      expiresAt: Date(timeIntervalSince1970: 4_102_444_800)
    )
  }
}

private enum CandidateConflictMode: Equatable, Sendable {
  case readyRotates
  case cardReturnsWaiting
  case confirmRotates
  case confirmSameGeneration
}

private actor CandidateConflictRendezvousClient: SocialRendezvousClient {
  private let sessionID = "candidate-conflict-session"
  private let nonce = "candidate-conflict-nonce"
  private let oldIdentity = RendezvousEncounterIdentity(
    id: "conflict-old-encounter",
    nonce: "conflict-old-nonce"
  )
  private let newIdentity = RendezvousEncounterIdentity(
    id: "conflict-new-encounter",
    nonce: "conflict-new-nonce"
  )
  private let mode: CandidateConflictMode
  private var participantID: String?
  private var currentIdentity: RendezvousEncounterIdentity?
  private var hasReturnedInitialMatch = false
  private var waiting = true

  init(mode: CandidateConflictMode) {
    self.mode = mode
  }

  func createSession(
    _ request: CreateRendezvousSessionRequest
  ) throws -> RendezvousSessionSnapshot {
    try SocialRendezvousValidation.validate(request)
    participantID = request.participantID
    return snapshot(status: .waitingForPeer)
  }

  func status(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validateSession(credentials)
    if !hasReturnedInitialMatch {
      currentIdentity = oldIdentity
      waiting = false
      hasReturnedInitialMatch = true
    }
    if waiting {
      return snapshot(status: .waitingForPeer)
    }
    return snapshot(
      status: .matched,
      identity: currentIdentity,
      peerToken: currentIdentity == oldIdentity ? Data([0x02]) : Data([0x03])
    )
  }

  func markProximityReady(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validateCandidate(credentials, identity: oldIdentity)
    if mode == .readyRotates {
      currentIdentity = newIdentity
      throw SocialRendezvousError.server(statusCode: 409)
    }
    return snapshot(
      status: .proximityReady,
      identity: oldIdentity,
      peerToken: Data([0x02]),
      proximityVerified: true
    )
  }

  func fetchPeerCard(
    _ credentials: RendezvousCredentials
  ) throws -> PeerCardSnapshot {
    try validateCandidate(credentials, identity: oldIdentity)
    if mode == .cardReturnsWaiting {
      currentIdentity = nil
      waiting = true
      throw SocialRendezvousError.server(statusCode: 409)
    }
    return PeerCardSnapshot(
      encounterID: oldIdentity.id,
      encounterNonce: oldIdentity.nonce,
      card: PublicPetCardV1(
        petName: "Conflict Peer",
        characterID: "pet.conflict",
        socialState: .greeting
      )
    )
  }

  func confirm(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validateCandidate(credentials, identity: oldIdentity)
    if mode == .confirmRotates {
      currentIdentity = newIdentity
    }
    throw SocialRendezvousError.server(statusCode: 409)
  }

  func cancel(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    throw SocialRendezvousError.invalidMockCredentials
  }

  private func validateSession(_ credentials: RendezvousCredentials) throws {
    guard credentials.sessionID == sessionID,
      credentials.participantID == participantID,
      credentials.nonce == nonce
    else {
      throw SocialRendezvousError.invalidMockCredentials
    }
  }

  private func validateCandidate(
    _ credentials: RendezvousCredentials,
    identity: RendezvousEncounterIdentity
  ) throws {
    try validateSession(credentials)
    guard credentials.encounterIdentity == identity else {
      throw SocialRendezvousError.encounterIdentityMismatch
    }
  }

  private func snapshot(
    status: RendezvousStatus,
    identity: RendezvousEncounterIdentity? = nil,
    peerToken: Data? = nil,
    proximityVerified: Bool = false
  ) -> RendezvousSessionSnapshot {
    RendezvousSessionSnapshot(
      sessionID: sessionID,
      nonce: status == .waitingForPeer ? nonce : nil,
      status: status,
      expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
      encounterID: identity?.id,
      encounterNonce: identity?.nonce,
      peerDiscoveryToken: peerToken,
      selfProximityReady: proximityVerified,
      peerProximityReady: proximityVerified,
      proximityVerified: proximityVerified
    )
  }
}

private actor ConfirmCancelRaceRendezvousClient: SocialRendezvousClient {
  private let sessionID = "race-session"
  private let nonce = "race-session-nonce"
  private let identity = RendezvousEncounterIdentity(
    id: "race-encounter",
    nonce: "race-encounter-nonce"
  )
  private var participantID: String?
  private var serverConfirmed = false
  private var confirmReachedServer = false
  private var confirmWaiters: [CheckedContinuation<Void, Never>] = []
  private var confirmRelease: CheckedContinuation<Void, Never>?
  private(set) var statusCount = 0
  private(set) var cancelCount = 0

  func createSession(
    _ request: CreateRendezvousSessionRequest
  ) throws -> RendezvousSessionSnapshot {
    try SocialRendezvousValidation.validate(request)
    participantID = request.participantID
    return snapshot(status: .waitingForPeer, includeSessionNonce: true)
  }

  func status(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validateSession(credentials)
    statusCount += 1
    if serverConfirmed {
      return snapshot(status: .confirmed, proximityVerified: true)
    }
    return snapshot(
      status: .matched,
      peerToken: Data([0x02])
    )
  }

  func markProximityReady(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validateCandidate(credentials)
    return snapshot(
      status: .proximityReady,
      peerToken: Data([0x02]),
      proximityVerified: true
    )
  }

  func fetchPeerCard(
    _ credentials: RendezvousCredentials
  ) throws -> PeerCardSnapshot {
    try validateCandidate(credentials)
    return PeerCardSnapshot(
      encounterID: identity.id,
      encounterNonce: identity.nonce,
      card: PublicPetCardV1(
        petName: "Race Peer",
        characterID: "pet.race",
        socialState: .greeting
      )
    )
  }

  func confirm(
    _ credentials: RendezvousCredentials
  ) async throws -> RendezvousSessionSnapshot {
    try validateCandidate(credentials)
    serverConfirmed = true
    confirmReachedServer = true
    let waiters = confirmWaiters
    confirmWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      confirmRelease = continuation
    }
    return snapshot(status: .confirmed, proximityVerified: true)
  }

  func cancel(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validateCandidate(credentials)
    cancelCount += 1
    if serverConfirmed {
      throw SocialRendezvousError.server(statusCode: 409)
    }
    return snapshot(status: .cancelled)
  }

  func waitUntilConfirmReachedServer() async {
    guard !confirmReachedServer else { return }
    await withCheckedContinuation { continuation in
      confirmWaiters.append(continuation)
    }
  }

  func releaseConfirmResponse() {
    confirmRelease?.resume()
    confirmRelease = nil
  }

  private func validateSession(_ credentials: RendezvousCredentials) throws {
    guard credentials.sessionID == sessionID,
      credentials.participantID == participantID,
      credentials.nonce == nonce
    else {
      throw SocialRendezvousError.invalidMockCredentials
    }
  }

  private func validateCandidate(_ credentials: RendezvousCredentials) throws {
    try validateSession(credentials)
    guard credentials.encounterIdentity == identity else {
      throw SocialRendezvousError.encounterIdentityMismatch
    }
  }

  private func snapshot(
    status: RendezvousStatus,
    includeSessionNonce: Bool = false,
    peerToken: Data? = nil,
    proximityVerified: Bool = false
  ) -> RendezvousSessionSnapshot {
    RendezvousSessionSnapshot(
      sessionID: sessionID,
      nonce: includeSessionNonce ? nonce : nil,
      status: status,
      expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
      encounterID: status == .waitingForPeer ? nil : identity.id,
      encounterNonce: status == .waitingForPeer ? nil : identity.nonce,
      peerDiscoveryToken: peerToken,
      selfProximityReady: proximityVerified,
      peerProximityReady: proximityVerified,
      proximityVerified: proximityVerified,
      selfPreviewReleased: proximityVerified,
      peerPreviewReleased: proximityVerified,
      selfConfirmed: serverConfirmed,
      peerConfirmed: serverConfirmed
    )
  }
}

private actor RotatingCancelRendezvousClient: SocialRendezvousClient {
  private let sessionID = "rotating-cancel-session"
  private let nonce = "rotating-cancel-nonce"
  private let oldIdentity = RendezvousEncounterIdentity(
    id: "cancel-old-encounter",
    nonce: "cancel-old-nonce"
  )
  private let newIdentity = RendezvousEncounterIdentity(
    id: "cancel-new-encounter",
    nonce: "cancel-new-nonce"
  )
  private var participantID: String?
  private var currentIdentity: RendezvousEncounterIdentity?
  private var shouldFailNewCancellation = true
  private(set) var statusCount = 0
  private(set) var cancelledIdentities: [RendezvousEncounterIdentity] = []

  func createSession(
    _ request: CreateRendezvousSessionRequest
  ) throws -> RendezvousSessionSnapshot {
    try SocialRendezvousValidation.validate(request)
    participantID = request.participantID
    return snapshot(
      status: .waitingForPeer,
      includeSessionNonce: true
    )
  }

  func status(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validateSession(credentials)
    statusCount += 1
    if currentIdentity == nil {
      currentIdentity = oldIdentity
    }
    return snapshot(
      status: .matched,
      identity: currentIdentity,
      peerToken: currentIdentity == oldIdentity ? Data([0x02]) : Data([0x03])
    )
  }

  func markProximityReady(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    throw SocialRendezvousError.invalidMockCredentials
  }

  func fetchPeerCard(
    _ credentials: RendezvousCredentials
  ) throws -> PeerCardSnapshot {
    throw SocialRendezvousError.invalidMockCredentials
  }

  func confirm(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    throw SocialRendezvousError.invalidMockCredentials
  }

  func cancel(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validateSession(credentials)
    guard let requestedIdentity = credentials.encounterIdentity else {
      throw SocialRendezvousError.missingCredentials
    }
    cancelledIdentities.append(requestedIdentity)
    if requestedIdentity == oldIdentity {
      currentIdentity = newIdentity
      throw SocialRendezvousError.server(statusCode: 409)
    }
    guard requestedIdentity == newIdentity,
      currentIdentity == newIdentity
    else {
      throw SocialRendezvousError.encounterIdentityMismatch
    }
    if shouldFailNewCancellation {
      shouldFailNewCancellation = false
      throw SocialRendezvousError.server(statusCode: 503)
    }
    return snapshot(status: .cancelled, identity: newIdentity)
  }

  private func validateSession(_ credentials: RendezvousCredentials) throws {
    guard credentials.sessionID == sessionID,
      credentials.participantID == participantID,
      credentials.nonce == nonce
    else {
      throw SocialRendezvousError.invalidMockCredentials
    }
  }

  private func snapshot(
    status: RendezvousStatus,
    includeSessionNonce: Bool = false,
    identity: RendezvousEncounterIdentity? = nil,
    peerToken: Data? = nil
  ) -> RendezvousSessionSnapshot {
    RendezvousSessionSnapshot(
      sessionID: sessionID,
      nonce: includeSessionNonce ? nonce : nil,
      status: status,
      expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
      encounterID: identity?.id,
      encounterNonce: identity?.nonce,
      peerDiscoveryToken: peerToken
    )
  }
}

private actor DelayedReplacementRendezvousClient: SocialRendezvousClient {
  private let sessionID = "delayed-session"
  private let nonce = "delayed-nonce"
  private let oldIdentity = RendezvousEncounterIdentity(
    id: "old-encounter",
    nonce: "old-encounter-nonce"
  )
  private let newIdentity = RendezvousEncounterIdentity(
    id: "new-encounter",
    nonce: "new-encounter-nonce"
  )
  private var participantID: String?
  private var statusCount = 0
  private var markStarted = false
  private var markStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var markRelease: CheckedContinuation<Void, Never>?
  private(set) var peerCardFetchCount = 0

  func createSession(
    _ request: CreateRendezvousSessionRequest
  ) throws -> RendezvousSessionSnapshot {
    try SocialRendezvousValidation.validate(request)
    participantID = request.participantID
    return snapshot(status: .waitingForPeer, includeSessionNonce: true)
  }

  func status(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    let expectedIdentity = statusCount == 0 ? nil : oldIdentity
    try validate(credentials, expectedIdentity: expectedIdentity)
    statusCount += 1
    if statusCount == 1 {
      return snapshot(
        status: .matched,
        identity: oldIdentity,
        peerToken: Data([0x02])
      )
    }
    return snapshot(
      status: .matched,
      identity: newIdentity,
      peerToken: Data([0x03])
    )
  }

  func markProximityReady(
    _ credentials: RendezvousCredentials
  ) async throws -> RendezvousSessionSnapshot {
    try validate(credentials, expectedIdentity: oldIdentity)
    markStarted = true
    let waiters = markStartWaiters
    markStartWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      markRelease = continuation
    }
    return snapshot(
      status: .proximityReady,
      identity: oldIdentity,
      peerToken: Data([0x02]),
      proximityVerified: true
    )
  }

  func fetchPeerCard(
    _ credentials: RendezvousCredentials
  ) throws -> PeerCardSnapshot {
    peerCardFetchCount += 1
    try validate(credentials, expectedIdentity: oldIdentity)
    return PeerCardSnapshot(
      encounterID: oldIdentity.id,
      encounterNonce: oldIdentity.nonce,
      card: PublicPetCardV1(
        petName: "Stale",
        characterID: "pet.stale",
        socialState: .greeting
      )
    )
  }

  func confirm(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    throw SocialRendezvousError.invalidMockCredentials
  }

  func cancel(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    throw SocialRendezvousError.invalidMockCredentials
  }

  func waitUntilMarkStarted() async {
    guard !markStarted else { return }
    await withCheckedContinuation { continuation in
      markStartWaiters.append(continuation)
    }
  }

  func releaseOldMark() {
    markRelease?.resume()
    markRelease = nil
  }

  private func validate(
    _ credentials: RendezvousCredentials,
    expectedIdentity: RendezvousEncounterIdentity?
  ) throws {
    guard credentials.sessionID == sessionID,
      credentials.participantID == participantID,
      credentials.nonce == nonce
    else {
      throw SocialRendezvousError.invalidMockCredentials
    }
    guard credentials.encounterIdentity == expectedIdentity else {
      throw SocialRendezvousError.encounterIdentityMismatch
    }
  }

  private func snapshot(
    status: RendezvousStatus,
    includeSessionNonce: Bool = false,
    identity: RendezvousEncounterIdentity? = nil,
    peerToken: Data? = nil,
    proximityVerified: Bool = false
  ) -> RendezvousSessionSnapshot {
    RendezvousSessionSnapshot(
      sessionID: sessionID,
      nonce: includeSessionNonce ? nonce : nil,
      status: status,
      expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
      encounterID: identity?.id,
      encounterNonce: identity?.nonce,
      peerDiscoveryToken: peerToken,
      selfProximityReady: proximityVerified,
      peerProximityReady: proximityVerified,
      proximityVerified: proximityVerified
    )
  }
}

private actor RotatingMockSocialRendezvousClient: SocialRendezvousClient {
  private let sessionID = "rotation-session"
  private let nonce = "rotation-nonce"
  private var participantID: String?
  private var statusCount = 0

  func createSession(
    _ request: CreateRendezvousSessionRequest
  ) throws -> RendezvousSessionSnapshot {
    try SocialRendezvousValidation.validate(request)
    participantID = request.participantID
    return snapshot(status: .waitingForPeer, includeNonce: true)
  }

  func status(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validate(credentials)
    statusCount += 1
    switch statusCount {
    case 1:
      return snapshot(
        status: .matched,
        encounterID: "initial-encounter",
        encounterNonce: "initial-encounter-nonce",
        peerToken: Data([0x02])
      )
    default:
      return snapshot(
        status: .matched,
        encounterID: "replacement-encounter",
        encounterNonce: "replacement-encounter-nonce",
        peerToken: Data([0x03])
      )
    }
  }

  func markProximityReady(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validate(credentials)
    return snapshot(status: .matched)
  }

  func fetchPeerCard(
    _ credentials: RendezvousCredentials
  ) throws -> PeerCardSnapshot {
    try validate(credentials)
    throw SocialRendezvousError.invalidMockCredentials
  }

  func confirm(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validate(credentials)
    throw SocialRendezvousError.invalidMockCredentials
  }

  func cancel(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validate(credentials)
    return snapshot(status: .cancelled)
  }

  private func validate(_ credentials: RendezvousCredentials) throws {
    guard credentials.sessionID == sessionID,
      credentials.participantID == participantID,
      credentials.nonce == nonce
    else {
      throw SocialRendezvousError.invalidMockCredentials
    }
    let expectedIdentity: RendezvousEncounterIdentity?
    switch statusCount {
    case 0:
      expectedIdentity = nil
    case 1:
      expectedIdentity = RendezvousEncounterIdentity(
        id: "initial-encounter",
        nonce: "initial-encounter-nonce"
      )
    default:
      expectedIdentity = RendezvousEncounterIdentity(
        id: "replacement-encounter",
        nonce: "replacement-encounter-nonce"
      )
    }
    guard credentials.encounterIdentity == expectedIdentity else {
      throw SocialRendezvousError.encounterIdentityMismatch
    }
  }

  private func snapshot(
    status: RendezvousStatus,
    includeNonce: Bool = false,
    encounterID: String? = nil,
    encounterNonce: String? = nil,
    peerToken: Data? = nil
  ) -> RendezvousSessionSnapshot {
    RendezvousSessionSnapshot(
      sessionID: sessionID,
      nonce: includeNonce ? nonce : nil,
      status: status,
      expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
      encounterID: encounterID,
      encounterNonce: encounterNonce,
      peerDiscoveryToken: peerToken
    )
  }
}
