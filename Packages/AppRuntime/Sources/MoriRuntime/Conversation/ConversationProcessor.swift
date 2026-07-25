import Foundation
import MoriDomain
import MoriPersistence

public struct ConversationAppContextInput: Hashable, Sendable {
  public let identity: MoriIdentity
  public let tone: MoriTone
  public let approvedEventIDs: [EventID]
  public let selectedMemoryExcerpt: SelectedMemoryExcerpt?
  public let selectedMemoryRevision: LamportRevision?

  public init(
    identity: MoriIdentity,
    tone: MoriTone,
    approvedEventIDs: [EventID] = [],
    selectedMemoryExcerpt: SelectedMemoryExcerpt? = nil,
    selectedMemoryRevision: LamportRevision? = nil
  ) {
    self.identity = identity
    self.tone = tone
    self.approvedEventIDs = approvedEventIDs
    self.selectedMemoryExcerpt = selectedMemoryExcerpt
    self.selectedMemoryRevision = selectedMemoryRevision
  }
}

public actor ConversationProcessor {
  public typealias StateObserver =
    @Sendable (ConversationPresentationState) async -> Void

  private let profile: RuntimeProfile
  private let repository: any ConversationRepositoryAccessing
  private let authority: any ChatAuthorityProviding
  private let transport: any ChatTransport
  private let configuration: ConversationRuntimeConfiguration
  private let scanner: ConversationPrivacyScanner
  private let audit: any ConversationAuditRecording
  private let codec = CanonicalJSONCodec()
  private var cancelledRequestIDs: Set<String> = []

  public init(
    profile: RuntimeProfile,
    repository: any ConversationRepositoryAccessing,
    authority: any ChatAuthorityProviding,
    transport: any ChatTransport,
    configuration: ConversationRuntimeConfiguration = .standard,
    scanner: ConversationPrivacyScanner = ConversationPrivacyScanner(),
    audit: any ConversationAuditRecording = NoopConversationAuditRecorder()
  ) throws {
    guard profile.isValid, configuration.isValid else {
      throw ConversationFailure.invalidProfile
    }
    self.profile = profile
    self.repository = repository
    self.authority = authority
    self.transport = transport
    self.configuration = configuration
    self.scanner = scanner
    self.audit = audit
  }

  public func load() async -> ConversationPresentationState {
    do {
      let state = try await repository.current()
      let chatAuthority = try await authority.currentChatAuthority()
      guard chatAuthority.profile == profile else {
        return presentation(
          from: state,
          phase: .failed(
            requestID: nil,
            failure: .staleAuthority
          ),
          authority: chatAuthority
        )
      }
      return presentation(
        from: state,
        phase: .idle,
        authority: chatAuthority
      )
    } catch {
      return ConversationPresentationState(
        messages: [],
        phase: .failed(
          requestID: nil,
          failure: .persistenceFailure
        ),
        memoryContextIsEnabled: false
      )
    }
  }

  @discardableResult
  public func setDraft(
    _ draft: String
  ) async -> ConversationPresentationState {
    do {
      let state = try await repository.setDraft(draft)
      let chatAuthority = try await authority.currentChatAuthority()
      return presentation(
        from: state,
        phase: .idle,
        authority: chatAuthority
      )
    } catch {
      return await failurePresentation(
        requestID: nil,
        failure: .persistenceFailure
      )
    }
  }

  public func send(
    _ explicitMessage: String,
    appContext: ConversationAppContextInput,
    mode: ChatTransportMode,
    confirmedWarnings: Bool = false,
    requestID: String = UUID().uuidString,
    clientTurnID: String = UUID().uuidString,
    onState: @escaping StateObserver = { _ in }
  ) async -> ConversationPresentationState {
    await performSend(
      explicitMessage,
      appContext: appContext,
      mode: mode,
      confirmedWarnings: confirmedWarnings,
      requestID: requestID,
      clientTurnID: clientTurnID,
      shouldBeginTurn: true,
      onState: onState
    )
  }

  public func retry(
    requestID: String,
    appContext: ConversationAppContextInput,
    mode: ChatTransportMode,
    onState: @escaping StateObserver = { _ in }
  ) async -> ConversationPresentationState {
    do {
      let state = try await repository.current()
      guard
        let pending = state.pendingTurns.first(where: {
          $0.requestID == requestID
        }),
        let userMessage = state.messages.first(where: {
          $0.header.recordID == pending.userRecordID
            && $0.role == .user
        })
      else {
        return await failurePresentation(
          requestID: requestID,
          failure: .providerFailure
        )
      }
      cancelledRequestIDs.remove(requestID)
      return await performSend(
        userMessage.content,
        appContext: appContext,
        mode: mode,
        confirmedWarnings: true,
        requestID: requestID,
        clientTurnID: pending.clientTurnID,
        shouldBeginTurn: false,
        onState: onState
      )
    } catch {
      return await failurePresentation(
        requestID: requestID,
        failure: .persistenceFailure
      )
    }
  }

  public func cancel(
    requestID: String
  ) {
    cancelledRequestIDs.insert(requestID)
  }

  public func clear(
    requestID: String
  ) async -> ConversationPresentationState {
    do {
      let current = try await repository.current()
      cancelledRequestIDs.formUnion(current.pendingTurns.map(\.requestID))
      let state = try await repository.clear(requestID: requestID)
      let chatAuthority = try await authority.currentChatAuthority()
      return presentation(
        from: state,
        phase: .idle,
        authority: chatAuthority
      )
    } catch {
      return await failurePresentation(
        requestID: nil,
        failure: .persistenceFailure
      )
    }
  }

  public func revokeMemory(
    _ memoryID: MemoryID
  ) async -> ConversationPresentationState {
    do {
      let state = try await repository.revokeMemory(memoryID)
      let chatAuthority = try await authority.currentChatAuthority()
      return presentation(
        from: state,
        phase: .idle,
        authority: chatAuthority
      )
    } catch {
      return await failurePresentation(
        requestID: nil,
        failure: .persistenceFailure
      )
    }
  }

  public func clearMemoryContextIndex() async -> ConversationPresentationState {
    do {
      let current = try await repository.current()
      let state = try await repository.replaceContextIndex(
        [],
        expectedClearGeneration: current.clearGeneration
      )
      let chatAuthority = try await authority.currentChatAuthority()
      return presentation(
        from: state,
        phase: .idle,
        authority: chatAuthority
      )
    } catch {
      return await failurePresentation(
        requestID: nil,
        failure: .persistenceFailure
      )
    }
  }

  public func removeAllContent() async throws {
    let current = try await repository.current()
    cancelledRequestIDs.formUnion(current.pendingTurns.map(\.requestID))
    try await repository.removeAllContent()
  }

  private func performSend(
    _ explicitMessage: String,
    appContext input: ConversationAppContextInput,
    mode: ChatTransportMode,
    confirmedWarnings: Bool,
    requestID: String,
    clientTurnID: String,
    shouldBeginTurn: Bool,
    onState: @escaping StateObserver
  ) async -> ConversationPresentationState {
    let scan = scanner.scan(explicitMessage)
    if scan.blocked {
      await audit.record(
        ConversationAuditEvent(
          requestID: requestID,
          outcome: .blockedCredential
        )
      )
      let state = await failurePresentation(
        requestID: requestID,
        failure: .unsafeInput,
        warnings: scan.warnings
      )
      await onState(state)
      return state
    }
    if scan.warnings.isEmpty == false, confirmedWarnings == false {
      await audit.record(
        ConversationAuditEvent(
          requestID: requestID,
          outcome: .warningAwaitingConfirmation
        )
      )
      let state = await warningPresentation(scan.warnings)
      await onState(state)
      return state
    }

    do {
      var state = try await repository.current()
      let currentAuthority = try await authority.currentChatAuthority()
      let appContext = try await sanitizedContext(
        input,
        authority: currentAuthority,
        expectedClearGeneration: state.clearGeneration
      )
      let lease = try makeLease(
        requestID: requestID,
        clientTurnID: clientTurnID,
        state: state,
        authority: currentAuthority,
        mode: mode,
        includesMemoryContext: appContext.selectedMemoryExcerpt != nil
      )
      if mode != .localMock {
        state = try await repository.recordFirstSendDisclosure(
          version: currentAuthority.remoteChatConsent.disclosureVersion
        )
      }

      if shouldBeginTurn {
        switch try await repository.beginTurn(
          requestID: requestID,
          clientTurnID: clientTurnID,
          expectedClearGeneration:
            lease.conversationClearGeneration,
          explicitMessage: explicitMessage,
          at: Date()
        ) {
        case .inserted(let inserted), .duplicate(let inserted):
          state = inserted
        }
      }
      try await validate(
        lease: lease,
        mode: mode
      )

      let request = try makeRequest(
        explicitMessage: explicitMessage,
        appContext: appContext,
        lease: lease,
        state: state
      )
      let sending = presentation(
        from: state,
        phase: .sending(requestID: requestID),
        warnings: scan.warnings,
        authority: currentAuthority
      )
      await onState(sending)

      let response = try await receiveResponse(
        request: request,
        lease: lease,
        mode: mode,
        warnings: scan.warnings,
        onState: onState
      )
      try await validate(
        lease: lease,
        mode: mode
      )
      try validateResponse(
        response,
        request: request,
        lease: lease
      )
      let memoryIDs =
        appContext.selectedMemoryExcerpt.map {
          [$0.memoryID]
        } ?? []
      let completed: ConversationRepositoryState
      switch try await repository.appendReply(
        requestID: requestID,
        clientTurnID: clientTurnID,
        clearGeneration: lease.conversationClearGeneration,
        content: response.replyText,
        referencedMemoryIDs: memoryIDs,
        at: Date()
      ) {
      case .inserted(let state), .duplicate(let state):
        completed = state
      }
      try await validate(
        lease: lease,
        mode: mode,
        requiresPendingTurn: false
      )
      cancelledRequestIDs.remove(requestID)
      await audit.record(
        ConversationAuditEvent(
          requestID: requestID,
          outcome: .completed
        )
      )
      let latestAuthority = try await authority.currentChatAuthority()
      let final = presentation(
        from: completed,
        phase: .idle,
        warnings: scan.warnings,
        authority: latestAuthority
      )
      await onState(final)
      return final
    } catch {
      let failure = mapFailure(error)
      return await handleFailure(
        requestID: requestID,
        clientTurnID: clientTurnID,
        failure: failure,
        warnings: scan.warnings,
        onState: onState
      )
    }
  }

  private func sanitizedContext(
    _ input: ConversationAppContextInput,
    authority currentAuthority: ChatAuthoritySnapshot,
    expectedClearGeneration: UInt64
  ) async throws -> ChatAppContextV1 {
    guard currentAuthority.profile == profile else {
      throw ConversationFailure.staleAuthority
    }
    let selectedExcerpt: SelectedMemoryExcerpt?
    if currentAuthority.memoryContextIsAuthorized {
      selectedExcerpt = input.selectedMemoryExcerpt
      if let excerpt = selectedExcerpt {
        guard
          let revision = input.selectedMemoryRevision,
          revision.isValid
        else {
          throw ConversationFailure.unauthorized
        }
        _ = try await repository.replaceContextIndex(
          [
            ConversationMemoryContextIndexEntry(
              memoryID: excerpt.memoryID,
              memoryRevision: revision
            )
          ],
          expectedClearGeneration: expectedClearGeneration
        )
      } else {
        _ = try await repository.replaceContextIndex(
          [],
          expectedClearGeneration: expectedClearGeneration
        )
      }
    } else {
      selectedExcerpt = nil
      _ = try await repository.replaceContextIndex(
        [],
        expectedClearGeneration: expectedClearGeneration
      )
    }
    let context = ChatAppContextV1(
      identity: input.identity,
      tone: input.tone,
      approvedEventIDs: Array(Set(input.approvedEventIDs)).sorted(),
      selectedMemoryExcerpt: selectedExcerpt
    )
    guard
      context.isValid(
        memoryContextIsAuthorized:
          currentAuthority.memoryContextIsAuthorized,
        maximumMemoryExcerptScalars:
          configuration.maximumMemoryExcerptScalars
      )
    else {
      throw ConversationFailure.unauthorized
    }
    return context
  }

  private func makeLease(
    requestID: String,
    clientTurnID: String,
    state: ConversationRepositoryState,
    authority currentAuthority: ChatAuthoritySnapshot,
    mode: ChatTransportMode,
    includesMemoryContext: Bool
  ) throws -> ChatAuthorityLease {
    guard state.profile == profile, currentAuthority.profile == profile else {
      throw ConversationFailure.staleAuthority
    }
    switch mode {
    case .localMock:
      guard profile.isMock, transport.isolation == .localOnly else {
        throw ConversationFailure.invalidProfile
      }
    case .remotePreview:
      guard
        profile.isMock,
        transport.isolation == .production,
        currentAuthority.remoteChatIsAuthorized
      else {
        throw ConversationFailure.unauthorized
      }
    case .remote:
      guard
        profile.isMock == false,
        transport.isolation == .production,
        currentAuthority.remoteChatIsAuthorized
      else {
        throw ConversationFailure.unauthorized
      }
    }
    let lease = ChatAuthorityLease(
      requestID: requestID,
      clientTurnID: clientTurnID,
      profile: profile,
      conversationID: state.conversationID,
      conversationClearGeneration: state.clearGeneration,
      remoteChatConsentRevision:
        currentAuthority.remoteChatConsent.revision,
      memoryContextConsentRevision:
        includesMemoryContext
        ? currentAuthority.memoryContextConsent.revision
        : nil
    )
    guard lease.isValid else {
      throw ConversationFailure.invalidProfile
    }
    return lease
  }

  private func makeRequest(
    explicitMessage: String,
    appContext: ChatAppContextV1,
    lease: ChatAuthorityLease,
    state: ConversationRepositoryState
  ) throws -> ChatRequestEnvelopeV1 {
    let recentMessages = state.messages
      .filter {
        ($0.role == .user || $0.role == .mori)
          && $0.isDeleted == false
          && $0.header.recordID
            != ConversationRecordID("turn-\(lease.clientTurnID)-user")
      }
      .suffix(configuration.maximumRecentMessages)
      .map {
        ChatMessageV1(
          recordID: $0.header.recordID,
          role: $0.role,
          content: $0.content
        )
      }
    let request = ChatRequestEnvelopeV1(
      requestID: lease.requestID,
      clientTurnID: lease.clientTurnID,
      profile: lease.profile,
      conversationID: lease.conversationID,
      conversationClearGeneration:
        lease.conversationClearGeneration,
      remoteChatConsentRevision:
        lease.remoteChatConsentRevision,
      memoryContextConsentRevision:
        lease.memoryContextConsentRevision,
      explicitMessage: explicitMessage,
      recentMessages: recentMessages,
      appContext: appContext
    )
    guard
      request.isValid(
        for: lease,
        configuration: configuration
      )
    else {
      throw ConversationFailure.malformedResponse
    }
    let data = try codec.encode(request)
    guard data.count <= configuration.maximumRequestBytes else {
      throw ConversationFailure.oversizedResponse
    }
    return request
  }

  private func receiveResponse(
    request: ChatRequestEnvelopeV1,
    lease: ChatAuthorityLease,
    mode: ChatTransportMode,
    warnings: [ConversationScanIssue],
    onState: @escaping StateObserver
  ) async throws -> ChatResponseEnvelopeV1 {
    try await withThrowingTaskGroup(
      of: ChatResponseEnvelopeV1.self
    ) { group in
      group.addTask {
        var accumulated = ""
        var completed: ChatResponseEnvelopeV1?
        for try await event in self.transport.stream(
          request: request,
          lease: lease
        ) {
          try Task.checkCancellation()
          try await self.validate(lease: lease, mode: mode)
          switch event {
          case .chunk(let chunk):
            guard completed == nil else {
              throw ConversationFailure.malformedResponse
            }
            accumulated.append(chunk)
            guard
              accumulated.unicodeScalars.count
                <= self.configuration.maximumReplyScalars
            else {
              throw ConversationFailure.oversizedResponse
            }
            let repositoryState = try await self.repository.current()
            let authorityState = try await self.authority.currentChatAuthority()
            let presentation = self.presentation(
              from: repositoryState,
              phase: .streaming(
                requestID: lease.requestID,
                text: accumulated
              ),
              warnings: warnings,
              authority: authorityState
            )
            await onState(presentation)
          case .completed(let response):
            guard completed == nil else {
              throw ConversationFailure.malformedResponse
            }
            completed = response
          }
        }
        guard let completed else {
          throw ConversationFailure.malformedResponse
        }
        guard
          completed.replyText.unicodeScalars.count
            <= self.configuration.maximumReplyScalars
        else {
          throw ConversationFailure.oversizedResponse
        }
        guard accumulated == completed.replyText else {
          throw ConversationFailure.malformedResponse
        }
        return completed
      }
      group.addTask {
        try await Task.sleep(
          for: .seconds(self.configuration.requestTimeout)
        )
        throw ConversationFailure.timedOut
      }
      guard let response = try await group.next() else {
        throw ConversationFailure.providerFailure
      }
      group.cancelAll()
      return response
    }
  }

  private func validate(
    lease: ChatAuthorityLease,
    mode: ChatTransportMode,
    requiresPendingTurn: Bool = true
  ) async throws {
    try Task.checkCancellation()
    if cancelledRequestIDs.contains(lease.requestID) {
      throw ConversationFailure.cancelled
    }
    let currentAuthority = try await authority.currentChatAuthority()
    guard currentAuthority.profile == lease.profile else {
      throw ConversationFailure.staleAuthority
    }
    if mode != .localMock {
      guard
        currentAuthority.remoteChatIsAuthorized,
        currentAuthority.remoteChatConsent.revision
          == lease.remoteChatConsentRevision
      else {
        throw ConversationFailure.staleAuthority
      }
    }
    if let memoryRevision = lease.memoryContextConsentRevision {
      guard
        currentAuthority.memoryContextIsAuthorized,
        currentAuthority.memoryContextConsent.revision == memoryRevision
      else {
        if let state = try? await repository.current() {
          _ = try? await repository.replaceContextIndex(
            [],
            expectedClearGeneration: state.clearGeneration
          )
        }
        throw ConversationFailure.staleAuthority
      }
    }
    let state = try await repository.current()
    guard
      state.profile == lease.profile,
      state.conversationID == lease.conversationID,
      state.clearGeneration == lease.conversationClearGeneration
    else {
      throw ConversationFailure.staleAuthority
    }
    if requiresPendingTurn,
      state.pendingTurns.contains(where: {
        $0.requestID == lease.requestID
          && $0.clientTurnID == lease.clientTurnID
      }) == false
    {
      throw ConversationFailure.staleAuthority
    }
  }

  private func validateResponse(
    _ response: ChatResponseEnvelopeV1,
    request: ChatRequestEnvelopeV1,
    lease: ChatAuthorityLease
  ) throws {
    guard
      response.isValid(
        for: lease,
        configuration: configuration,
        approvedEventIDs: Set(request.appContext.approvedEventIDs)
      )
    else {
      if response.replyText.unicodeScalars.count
        > configuration.maximumReplyScalars
      {
        throw ConversationFailure.oversizedResponse
      }
      throw ConversationFailure.malformedResponse
    }
    let data = try codec.encode(response)
    guard data.count <= configuration.maximumResponseBytes else {
      throw ConversationFailure.oversizedResponse
    }
  }

  private func handleFailure(
    requestID: String,
    clientTurnID: String,
    failure: ConversationFailure,
    warnings: [ConversationScanIssue],
    onState: @escaping StateObserver
  ) async -> ConversationPresentationState {
    let outcome = auditOutcome(for: failure)
    await audit.record(
      ConversationAuditEvent(
        requestID: requestID,
        outcome: outcome
      )
    )
    do {
      var state = try await repository.current()
      if failure.isRetryable {
        _ = try await repository.retainPendingTurnForRetry(
          requestID: requestID
        )
        if let fallback = ConversationLocalFallback.response(for: failure),
          let pending = state.pendingTurns.first(where: {
            $0.requestID == requestID
          })
        {
          state = try await repository.appendLocalFallback(
            requestID: requestID,
            clientTurnID: clientTurnID,
            clearGeneration: pending.clearGeneration,
            content: fallback,
            at: Date()
          )
        }
      } else {
        _ = try? await repository.abandonPendingTurn(
          requestID: requestID
        )
        state = try await repository.current()
      }
      let currentAuthority = try await authority.currentChatAuthority()
      let result = presentation(
        from: state,
        phase: .failed(
          requestID: requestID,
          failure: failure
        ),
        warnings: warnings,
        canRetry: failure.isRetryable,
        pendingRetryRequestID:
          failure.isRetryable ? requestID : nil,
        authority: currentAuthority
      )
      await onState(result)
      return result
    } catch {
      let result = await failurePresentation(
        requestID: requestID,
        failure: .persistenceFailure,
        warnings: warnings
      )
      await onState(result)
      return result
    }
  }

  private func warningPresentation(
    _ warnings: [ConversationScanIssue]
  ) async -> ConversationPresentationState {
    do {
      let state = try await repository.current()
      let chatAuthority = try await authority.currentChatAuthority()
      return presentation(
        from: state,
        phase: .warningConfirmationRequired,
        warnings: warnings,
        authority: chatAuthority
      )
    } catch {
      return ConversationPresentationState(
        messages: [],
        phase: .failed(
          requestID: nil,
          failure: .persistenceFailure
        ),
        memoryContextIsEnabled: false
      )
    }
  }

  private func failurePresentation(
    requestID: String?,
    failure: ConversationFailure,
    warnings: [ConversationScanIssue] = []
  ) async -> ConversationPresentationState {
    do {
      let state = try await repository.current()
      let chatAuthority = try await authority.currentChatAuthority()
      return presentation(
        from: state,
        phase: .failed(
          requestID: requestID,
          failure: failure
        ),
        warnings: warnings,
        canRetry: failure.isRetryable,
        pendingRetryRequestID:
          failure.isRetryable ? requestID : nil,
        authority: chatAuthority
      )
    } catch {
      return ConversationPresentationState(
        messages: [],
        phase: .failed(
          requestID: requestID,
          failure: .persistenceFailure
        ),
        warnings: warnings,
        memoryContextIsEnabled: false
      )
    }
  }

  private nonisolated func presentation(
    from state: ConversationRepositoryState,
    phase: ConversationPresentationPhase,
    warnings: [ConversationScanIssue] = [],
    canRetry: Bool = false,
    pendingRetryRequestID: String? = nil,
    authority chatAuthority: ChatAuthoritySnapshot
  ) -> ConversationPresentationState {
    ConversationPresentationState(
      messages: state.messages.filter { $0.isDeleted == false },
      draft: state.draft ?? "",
      phase: phase,
      warnings: warnings,
      canRetry: canRetry,
      pendingRetryRequestID: pendingRetryRequestID,
      memoryContextIsEnabled:
        chatAuthority.memoryContextIsAuthorized
    )
  }

  private func mapFailure(
    _ error: any Error
  ) -> ConversationFailure {
    if let failure = error as? ConversationFailure {
      return failure
    }
    if error is CancellationError {
      return .cancelled
    }
    if let repositoryError = error as? ConversationRepositoryError {
      switch repositoryError {
      case .profileMismatch, .staleClearGeneration, .staleStorageRevision,
        .retiredStorage:
        return .staleAuthority
      default:
        return .persistenceFailure
      }
    }
    return .providerFailure
  }

  private func auditOutcome(
    for failure: ConversationFailure
  ) -> ConversationAuditOutcome {
    switch failure {
    case .cancelled:
      .cancelled
    case .offline:
      .offline
    case .timedOut:
      .timedOut
    case .rateLimited:
      .rateLimited
    case .providerFailure, .unavailable, .unauthorized, .invalidProfile,
      .unsafeInput:
      .providerFailure
    case .malformedResponse:
      .malformedResponse
    case .oversizedResponse:
      .oversizedResponse
    case .staleAuthority:
      .staleAuthority
    case .persistenceFailure:
      .persistenceFailure
    }
  }
}
