import AppleAdapters
import Foundation

/// Orchestrates the transport and ranging boundaries while keeping all product
/// decisions in `EncounterStateMachine`.
public actor TouchExchangeCoordinator {
  private let rangingClient: any NearbyRangingClient
  private let rendezvousClient: any SocialRendezvousClient
  private var stateMachine: EncounterStateMachine
  private var credentials: RendezvousCredentials?
  private var pendingCreateRequest: CreateRendezvousSessionRequest?
  private var activePeerToken: NearbyDiscoveryToken?
  private var candidateGeneration: UInt64 = 0
  private var proximitySubmitted = false
  private var confirmationInFlight = false
  private var cancellationInFlight = false
  private var cancellationAttempt: UInt64 = 0
  private var remoteCancellationSucceeded = false
  private var rangingEventTask: Task<Void, Never>?

  public init(
    rangingClient: any NearbyRangingClient,
    rendezvousClient: any SocialRendezvousClient,
    proximityPolicy: ProximityStabilityPolicy = ProximityStabilityPolicy()
  ) {
    self.rangingClient = rangingClient
    self.rendezvousClient = rendezvousClient
    stateMachine = EncounterStateMachine(configuration: proximityPolicy)
  }

  deinit {
    rangingEventTask?.cancel()
  }

  public var state: EncounterState {
    stateMachine.state
  }

  @discardableResult
  public func start(
    participantID: String,
    publicCard: PublicPetCardV1,
    joinRequestID: String
  ) async throws -> EncounterState {
    startObservingRangingEventsIfNeeded()
    advanceGeneration()
    await rangingClient.stop()
    credentials = nil
    pendingCreateRequest = nil
    activePeerToken = nil
    resetCandidateOperations()
    remoteCancellationSucceeded = false
    cancellationAttempt &+= 1
    cancellationInFlight = false
    stateMachine.startRendezvous(participantID: participantID)
    let operationGeneration = candidateGeneration

    do {
      let localToken = try await rangingClient.prepareLocalToken()
      guard operationGeneration == candidateGeneration else {
        return stateMachine.state
      }
      let createRequest = CreateRendezvousSessionRequest(
        participantID: participantID,
        discoveryToken: localToken,
        publicCard: publicCard,
        joinRequestID: joinRequestID
      )
      pendingCreateRequest = createRequest
      let snapshot = try await rendezvousClient.createSession(
        createRequest
      )
      guard operationGeneration == candidateGeneration else {
        return stateMachine.state
      }
      guard let nonce = snapshot.nonce else {
        throw SocialRendezvousError.missingNonce
      }
      credentials = RendezvousCredentials(
        sessionID: snapshot.sessionID,
        participantID: participantID,
        nonce: nonce
      )
      pendingCreateRequest = nil
      try stateMachine.updateRendezvous(sessionID: snapshot.sessionID)
      _ = try await reconcile(snapshot)
      return stateMachine.state
    } catch {
      guard operationGeneration == candidateGeneration else {
        return stateMachine.state
      }
      await stopAfterRangingFailure()
      stateMachine.fail(
        EncounterFailure(code: "start_failed", message: String(describing: error))
      )
      throw error
    }
  }

  /// Polls the rendezvous only when the caller chooses to do so. Every request
  /// is bound to the current encounter generation; a late response from an old
  /// candidate is ignored.
  @discardableResult
  public func refresh(now: Date = Date()) async throws -> EncounterState {
    if cancellationInFlight
      || [.completed, .failed, .cancelled].contains(stateMachine.state.phase)
    {
      return stateMachine.state
    }
    guard let requestCredentials = credentials else { return stateMachine.state }
    let operationGeneration = candidateGeneration
    let snapshot = try await rendezvousClient.status(requestCredentials)
    guard isCurrent(operationGeneration, requestCredentials) else {
      return stateMachine.state
    }

    if snapshot.status == .expired {
      await rangingClient.stop()
      activePeerToken = nil
      stateMachine.fail(
        EncounterFailure(code: "session_expired", message: "Rendezvous session expired")
      )
      return stateMachine.state
    }
    if snapshot.status == .cancelled {
      remoteCancellationSucceeded = true
      stateMachine.cancel()
      await rangingClient.stop()
      activePeerToken = nil
      return stateMachine.state
    }

    let candidateChanged = try await reconcile(snapshot)
    if candidateChanged {
      return stateMachine.state
    }

    if stateMachine.state.phase == .ranging, proximitySubmitted {
      try await showPreviewIfPeerReady(snapshot, now: now)
    } else if [.preview, .awaitingConfirmations].contains(stateMachine.state.phase),
      snapshot.peerConfirmed == true || snapshot.status == .confirmed
    {
      try stateMachine.confirmPeer(now: now)
      if stateMachine.state.phase == .completed {
        await rangingClient.stop()
        activePeerToken = nil
      }
    }
    return stateMachine.state
  }

  @discardableResult
  public func processLatestMeasurement(now: Date = Date()) async throws -> EncounterState {
    let measurement = await rangingClient.latestMeasurement()
    return try await processMeasurement(measurement, now: now)
  }

  @discardableResult
  public func processMeasurement(
    _ measurement: NearbyMeasurement?,
    now: Date = Date()
  ) async throws -> EncounterState {
    guard !cancellationInFlight,
      stateMachine.state.phase == .ranging,
      let requestCredentials = credentials
    else {
      return stateMachine.state
    }
    let operationGeneration = candidateGeneration
    do {
      let isStable = try stateMachine.recordMeasurement(measurement, now: now)
      guard isStable else { return stateMachine.state }

      proximitySubmitted = true
      let snapshot = try await rendezvousClient.markProximityReady(requestCredentials)
      guard isCurrent(operationGeneration, requestCredentials) else {
        return stateMachine.state
      }
      let candidateChanged = try await reconcile(snapshot)
      guard !candidateChanged else { return stateMachine.state }
      try await showPreviewIfPeerReady(snapshot, now: now)
      return stateMachine.state
    } catch SocialRendezvousError.server(statusCode: 409) {
      if try await resolveCandidateConflict(
        requestCredentials: requestCredentials,
        operationGeneration: operationGeneration,
        now: now
      ) {
        return stateMachine.state
      }
      if isCurrent(operationGeneration, requestCredentials) {
        proximitySubmitted = false
      }
      throw SocialRendezvousError.server(statusCode: 409)
    } catch {
      if isCurrent(operationGeneration, requestCredentials) {
        proximitySubmitted = false
      }
      throw error
    }
  }

  @discardableResult
  public func confirm(now: Date = Date()) async throws -> EncounterState {
    if stateMachine.state.phase == .completed || confirmationInFlight
      || cancellationInFlight
    {
      return stateMachine.state
    }
    let peerConfirmedFirst =
      stateMachine.state.phase == .awaitingConfirmations
      && stateMachine.state.peerConfirmed
      && !stateMachine.state.localConfirmed
    if stateMachine.state.phase == .preview {
      try stateMachine.confirmLocal(now: now)
    }
    guard stateMachine.state.phase == .awaitingConfirmations else {
      throw EncounterTransitionError.invalidPhase(
        expected: [.preview, .awaitingConfirmations],
        actual: stateMachine.state.phase
      )
    }
    guard let requestCredentials = credentials,
      requestCredentials.encounterIdentity != nil
    else {
      throw SocialRendezvousError.missingCredentials
    }
    let operationGeneration = candidateGeneration
    confirmationInFlight = true
    defer {
      if operationGeneration == candidateGeneration {
        confirmationInFlight = false
      }
    }

    let snapshot: RendezvousSessionSnapshot
    do {
      snapshot = try await rendezvousClient.confirm(requestCredentials)
    } catch SocialRendezvousError.server(statusCode: 409) {
      if try await resolveCandidateConflict(
        requestCredentials: requestCredentials,
        operationGeneration: operationGeneration,
        now: now
      ) {
        return stateMachine.state
      }
      throw SocialRendezvousError.server(statusCode: 409)
    }
    guard isCurrent(operationGeneration, requestCredentials) else {
      return stateMachine.state
    }
    let candidateChanged = try await reconcile(snapshot)
    guard !candidateChanged else { return stateMachine.state }
    if peerConfirmedFirst {
      try stateMachine.confirmLocal(now: now)
    }
    if snapshot.peerConfirmed == true || snapshot.status == .confirmed {
      try stateMachine.confirmPeer(now: now)
    }
    if stateMachine.state.phase == .completed {
      await rangingClient.stop()
      activePeerToken = nil
    }
    return stateMachine.state
  }

  /// Stops local ranging immediately, but only exposes `.cancelled` after the
  /// server accepts the current encounter generation. A 409 is resolved through
  /// status so a confirmed encounter wins and a rotated candidate is retried.
  @discardableResult
  public func cancel(now: Date = Date()) async throws -> EncounterState {
    if stateMachine.state.phase == .completed || remoteCancellationSucceeded
      || cancellationInFlight
    {
      return stateMachine.state
    }

    cancellationAttempt &+= 1
    let attempt = cancellationAttempt
    cancellationInFlight = true
    defer {
      if cancellationAttempt == attempt {
        cancellationInFlight = false
      }
    }

    // Invalidate every operation that began before the user's cancellation.
    // In particular, a delayed confirm response must not overwrite the result
    // selected by the cancel/status race resolution below.
    advanceGeneration()
    resetCandidateOperations()
    activePeerToken = nil
    await rangingClient.stop()
    guard cancellationAttempt == attempt else {
      return stateMachine.state
    }

    if credentials == nil {
      guard let createRequest = pendingCreateRequest else {
        throw SocialRendezvousError.missingCredentials
      }
      let recoveryGeneration = candidateGeneration
      let snapshot = try await rendezvousClient.createSession(createRequest)
      guard cancellationAttempt == attempt,
        recoveryGeneration == candidateGeneration,
        pendingCreateRequest == createRequest
      else {
        return stateMachine.state
      }
      guard let nonce = snapshot.nonce else {
        throw SocialRendezvousError.missingNonce
      }
      let identity = try snapshot.encounterIdentity
      credentials = RendezvousCredentials(
        sessionID: snapshot.sessionID,
        participantID: createRequest.participantID,
        nonce: nonce,
        encounterID: identity?.id,
        encounterNonce: identity?.nonce
      )
      pendingCreateRequest = nil
      if stateMachine.state.phase == .rendezvous {
        try stateMachine.updateRendezvous(sessionID: snapshot.sessionID)
      }
      if snapshot.status == .cancelled || snapshot.status == .confirmed {
        return try applyCancellationTerminal(snapshot, now: now)
      }
      if snapshot.status == .expired {
        stateMachine.fail(
          EncounterFailure(code: "session_expired", message: "Rendezvous session expired")
        )
        return stateMachine.state
      }
    }

    let maximumGenerationRetries = 3
    for retry in 0...maximumGenerationRetries {
      guard let requestCredentials = credentials else {
        remoteCancellationSucceeded = true
        stateMachine.cancel()
        return stateMachine.state
      }
      let operationGeneration = candidateGeneration
      do {
        let snapshot = try await rendezvousClient.cancel(requestCredentials)
        guard cancellationAttempt == attempt,
          isCurrent(operationGeneration, requestCredentials)
        else {
          return stateMachine.state
        }
        return try applyCancellationTerminal(snapshot, now: now)
      } catch SocialRendezvousError.server(statusCode: 409) {
        guard cancellationAttempt == attempt,
          isCurrent(operationGeneration, requestCredentials)
        else {
          return stateMachine.state
        }
        let snapshot = try await rendezvousClient.status(requestCredentials)
        guard cancellationAttempt == attempt,
          isCurrent(operationGeneration, requestCredentials)
        else {
          return stateMachine.state
        }

        if snapshot.status == .confirmed || snapshot.status == .cancelled {
          return try applyCancellationTerminal(snapshot, now: now)
        }
        if snapshot.status == .expired {
          stateMachine.fail(
            EncounterFailure(code: "session_expired", message: "Rendezvous session expired")
          )
          return stateMachine.state
        }

        let advanced = try adoptCancellationGeneration(from: snapshot)
        guard advanced, retry < maximumGenerationRetries else {
          throw SocialRendezvousError.server(statusCode: 409)
        }
      }
    }
    throw SocialRendezvousError.server(statusCode: 409)
  }

  /// Allows an integration that already owns the Nearby event loop to forward
  /// failures explicitly. The coordinator also subscribes automatically after
  /// `start`.
  @discardableResult
  public func handleRangingEvent(_ event: NearbyRangingEvent) async -> EncounterState {
    guard !cancellationInFlight else { return stateMachine.state }
    switch event {
    case .measurement, .resumed, .reset(.peerChanged), .reset(.stopped):
      break
    case .suspended:
      if stateMachine.state.phase == .ranging {
        stateMachine.resetMeasurements()
        proximitySubmitted = false
      }
    case .failed, .reset(.peerRemoved), .reset(.sessionInvalidated):
      if activeCandidatePhases.contains(stateMachine.state.phase) {
        await stopAfterRangingFailure()
      }
    }
    return stateMachine.state
  }

  private func reconcile(
    _ snapshot: RendezvousSessionSnapshot
  ) async throws -> Bool {
    guard let currentCredentials = credentials,
      snapshot.sessionID == currentCredentials.sessionID
    else {
      throw SocialRendezvousError.encounterIdentityMismatch
    }
    let snapshotIdentity = try snapshot.encounterIdentity

    if snapshot.status == .waitingForPeer || snapshotIdentity == nil {
      if currentCredentials.encounterIdentity != nil || activePeerToken != nil {
        await returnToDiscovery(clearEncounterCredentials: true)
        return true
      }
      return false
    }

    guard let snapshotIdentity else {
      throw SocialRendezvousError.incompleteEncounterIdentity
    }
    let identityChanged = currentCredentials.encounterIdentity != snapshotIdentity
    let tokenChanged = snapshot.peerToken.map { activePeerToken != $0 } ?? false
    guard identityChanged || tokenChanged else {
      credentials = currentCredentials.replacingEncounter(with: snapshotIdentity)
      return false
    }
    guard let peerToken = snapshot.peerToken else {
      throw SocialRendezvousError.missingPeerToken
    }

    advanceGeneration()
    resetCandidateOperations()
    credentials = currentCredentials.replacingEncounter(with: snapshotIdentity)
    activePeerToken = peerToken
    try stateMachine.didMatch(
      sessionID: snapshot.sessionID,
      encounterID: snapshotIdentity.id
    )
    let installGeneration = candidateGeneration
    do {
      try await rangingClient.beginRanging(peerToken: peerToken)
      guard installGeneration == candidateGeneration else {
        return true
      }
      return true
    } catch {
      await stopAfterRangingFailure()
      throw error
    }
  }

  private func showPreviewIfPeerReady(
    _ snapshot: RendezvousSessionSnapshot,
    now: Date
  ) async throws {
    guard snapshot.proximityVerified == true,
      let requestCredentials = credentials,
      let expectedIdentity = requestCredentials.encounterIdentity
    else { return }
    let operationGeneration = candidateGeneration
    let peer: PeerCardSnapshot
    do {
      peer = try await rendezvousClient.fetchPeerCard(requestCredentials)
    } catch SocialRendezvousError.server(statusCode: 409) {
      if try await resolveCandidateConflict(
        requestCredentials: requestCredentials,
        operationGeneration: operationGeneration,
        now: now
      ) {
        return
      }
      throw SocialRendezvousError.server(statusCode: 409)
    }
    guard isCurrent(operationGeneration, requestCredentials) else { return }
    guard peer.encounterID == expectedIdentity.id,
      peer.encounterNonce == expectedIdentity.nonce
    else {
      throw SocialRendezvousError.encounterIdentityMismatch
    }
    try stateMachine.showPreview(peerCard: peer.card, encounterID: peer.encounterID)
  }

  /// A candidate endpoint can race server-side candidate rotation. Status is
  /// the authority: stale-generation conflicts are reconciled and consumed,
  /// while a 409 against the still-current identity remains a product error.
  private func resolveCandidateConflict(
    requestCredentials: RendezvousCredentials,
    operationGeneration: UInt64,
    now: Date
  ) async throws -> Bool {
    guard isCurrent(operationGeneration, requestCredentials) else {
      return true
    }
    let snapshot = try await rendezvousClient.status(requestCredentials)
    guard isCurrent(operationGeneration, requestCredentials) else {
      return true
    }
    guard snapshot.sessionID == requestCredentials.sessionID else {
      throw SocialRendezvousError.encounterIdentityMismatch
    }

    if snapshot.status == .cancelled {
      remoteCancellationSucceeded = true
      stateMachine.cancel()
      await rangingClient.stop()
      activePeerToken = nil
      return true
    }
    if snapshot.status == .expired {
      stateMachine.fail(
        EncounterFailure(code: "session_expired", message: "Rendezvous session expired")
      )
      await rangingClient.stop()
      activePeerToken = nil
      return true
    }
    if snapshot.status == .confirmed,
      [.preview, .awaitingConfirmations, .completed].contains(stateMachine.state.phase)
    {
      _ = try applyCancellationTerminal(snapshot, now: now)
      await rangingClient.stop()
      activePeerToken = nil
      return true
    }

    let snapshotIdentity = try snapshot.encounterIdentity
    if snapshot.status == .waitingForPeer
      || snapshotIdentity != requestCredentials.encounterIdentity
    {
      _ = try await reconcile(snapshot)
      return true
    }
    return false
  }

  private func applyCancellationTerminal(
    _ snapshot: RendezvousSessionSnapshot,
    now: Date
  ) throws -> EncounterState {
    guard let currentCredentials = credentials,
      snapshot.sessionID == currentCredentials.sessionID
    else {
      throw SocialRendezvousError.encounterIdentityMismatch
    }

    if snapshot.status == .cancelled {
      remoteCancellationSucceeded = true
      stateMachine.cancel()
      return stateMachine.state
    }

    guard snapshot.status == .confirmed,
      let currentIdentity = currentCredentials.encounterIdentity,
      try snapshot.encounterIdentity == currentIdentity,
      [.preview, .awaitingConfirmations, .completed].contains(stateMachine.state.phase)
    else {
      throw SocialRendezvousError.encounterIdentityMismatch
    }
    if !stateMachine.state.localConfirmed {
      try stateMachine.confirmLocal(now: now)
    }
    if !stateMachine.state.peerConfirmed {
      try stateMachine.confirmPeer(now: now)
    }
    return stateMachine.state
  }

  /// Applies only the identity portion of a conflict status. Cancellation must
  /// not restart Nearby Interaction while it chases a newly rotated candidate.
  private func adoptCancellationGeneration(
    from snapshot: RendezvousSessionSnapshot
  ) throws -> Bool {
    guard let currentCredentials = credentials,
      snapshot.sessionID == currentCredentials.sessionID
    else {
      throw SocialRendezvousError.encounterIdentityMismatch
    }
    let snapshotIdentity = try snapshot.encounterIdentity
    if snapshot.status != .waitingForPeer, snapshotIdentity == nil {
      throw SocialRendezvousError.incompleteEncounterIdentity
    }
    guard currentCredentials.encounterIdentity != snapshotIdentity else {
      return false
    }

    advanceGeneration()
    resetCandidateOperations()
    credentials = currentCredentials.replacingEncounter(with: snapshotIdentity)
    if activeCandidatePhases.contains(stateMachine.state.phase) {
      try stateMachine.didLoseCandidate()
    }
    return true
  }

  private func returnToDiscovery(clearEncounterCredentials: Bool) async {
    advanceGeneration()
    await rangingClient.stop()
    activePeerToken = nil
    resetCandidateOperations()
    if clearEncounterCredentials, let credentials {
      self.credentials = credentials.replacingEncounter(with: nil)
    }
    if activeCandidatePhases.contains(stateMachine.state.phase) {
      try? stateMachine.didLoseCandidate()
    }
  }

  private func stopAfterRangingFailure() async {
    await returnToDiscovery(clearEncounterCredentials: false)
  }

  private func resetCandidateOperations() {
    proximitySubmitted = false
    confirmationInFlight = false
  }

  private func advanceGeneration() {
    candidateGeneration &+= 1
  }

  private var activeCandidatePhases: Set<EncounterPhase> {
    [.ranging, .preview, .awaitingConfirmations]
  }

  private func isCurrent(
    _ generation: UInt64,
    _ requestCredentials: RendezvousCredentials
  ) -> Bool {
    generation == candidateGeneration && requestCredentials == credentials
  }

  private func startObservingRangingEventsIfNeeded() {
    guard rangingEventTask == nil else { return }
    let events = rangingClient.events()
    rangingEventTask = Task { [weak self] in
      for await event in events {
        guard !Task.isCancelled else { return }
        await self?.handleRangingEvent(event)
      }
    }
  }
}
