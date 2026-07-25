import Foundation
import MoriDomain
import Testing

@testable import MoriRuntime

@Suite("Authority-bounded conversation processor")
struct ConversationProcessorTests {
  @Test("Mock streams locally and persists one user and one Mori message")
  func localMockStreamCompletes() async throws {
    let fixture = try await makeFixture()
    let observer = ConversationStateObserver()

    let final = await fixture.processor.send(
      "今天有点累。",
      appContext: .init(identity: .penguin, tone: .gentle),
      mode: .localMock,
      requestID: "request-normal",
      clientTurnID: "turn-normal"
    ) {
      await observer.append($0)
    }

    #expect(final.messages.map(\.role) == [.user, .mori])
    #expect(final.messages.last?.content.contains("陪你") == true)
    #expect(final.phase == .idle)
    #expect(
      await observer.states.contains(where: {
        if case .streaming = $0.phase { return true }
        return false
      })
    )
    #expect(
      await fixture.audit.events
        == [
          ConversationAuditEvent(
            requestID: "request-normal",
            outcome: .completed
          )
        ]
    )
  }

  @Test("Credentials block before persistence while contact details require confirmation")
  func privacyPreflightIsFailClosed() async throws {
    let fixture = try await makeFixture()

    let blocked = await fixture.processor.send(
      "sk-" + "proj-" + String(repeating: "a", count: 32),
      appContext: .init(identity: .penguin, tone: .gentle),
      mode: .localMock,
      requestID: "request-secret",
      clientTurnID: "turn-secret"
    )
    #expect(
      blocked.phase
        == .failed(
          requestID: "request-secret",
          failure: .unsafeInput
        )
    )
    #expect(blocked.messages.isEmpty)

    let warning = await fixture.processor.send(
      "请记住 mori@example.com",
      appContext: .init(identity: .penguin, tone: .gentle),
      mode: .localMock,
      requestID: "request-warning",
      clientTurnID: "turn-warning"
    )
    #expect(warning.phase == .warningConfirmationRequired)
    #expect(warning.warnings == [.possibleContact(.email)])
    #expect(warning.messages.isEmpty)

    let confirmed = await fixture.processor.send(
      "请记住 mori@example.com",
      appContext: .init(identity: .penguin, tone: .gentle),
      mode: .localMock,
      confirmedWarnings: true,
      requestID: "request-warning",
      clientTurnID: "turn-warning"
    )
    #expect(confirmed.messages.map(\.role) == [.user, .mori])
  }

  @Test("Offline fallback stays local and retry reuses the original user turn")
  func offlineRetryIsIdempotent() async throws {
    let transport = MutableMockChatTransport(behavior: .offline)
    let fixture = try await makeFixture(transport: transport)

    let offline = await fixture.processor.send(
      "我们去散步吧。",
      appContext: .init(identity: .penguin, tone: .gentle),
      mode: .localMock,
      requestID: "request-retry",
      clientTurnID: "turn-retry"
    )
    #expect(offline.canRetry)
    #expect(offline.pendingRetryRequestID == "request-retry")
    #expect(offline.messages.map(\.role) == [.user, .localSystem])

    transport.setBehavior(.normal)
    let retried = await fixture.processor.retry(
      requestID: "request-retry",
      appContext: .init(identity: .penguin, tone: .gentle),
      mode: .localMock
    )
    #expect(
      retried.messages.filter { $0.role == .user }.count == 1
    )
    #expect(
      retried.messages.filter { $0.role == .mori }.count == 1
    )
    #expect(retried.phase == .idle)
    let requests = transport.capturedRequests()
    #expect(requests.count == 2)
    #expect(
      requests.last?.recentMessages.allSatisfy {
        $0.role != .localSystem
      } == true
    )
  }

  @Test("Malformed and oversized responses fail without assistant persistence")
  func invalidResponsesFailClosed() async throws {
    for (behavior, failure) in [
      (
        DeterministicMockChatBehavior.malformedResponse,
        ConversationFailure.malformedResponse
      ),
      (
        DeterministicMockChatBehavior.oversizedResponse,
        ConversationFailure.oversizedResponse
      ),
    ] {
      let fixture = try await makeFixture(
        transport: DeterministicMockChatTransport(
          behavior: behavior,
          configuration: fastConfiguration
        )
      )
      let final = await fixture.processor.send(
        "测试异常响应",
        appContext: .init(identity: .penguin, tone: .gentle),
        mode: .localMock,
        requestID: "request-\(behavior.rawValue)",
        clientTurnID: "turn-\(behavior.rawValue)"
      )
      #expect(
        final.phase
          == .failed(
            requestID: "request-\(behavior.rawValue)",
            failure: failure
          )
      )
      #expect(final.messages.contains(where: { $0.role == .mori }) == false)
    }
  }

  @Test("Clear during streaming prevents late response resurrection")
  func clearWinsAgainstStreaming() async throws {
    let configuration = ConversationRuntimeConfiguration(
      requestTimeout: 3,
      streamChunkDelay: 0.15
    )
    let fixture = try await makeFixture(
      transport: DeterministicMockChatTransport(
        behavior: .slowStream,
        configuration: configuration
      ),
      configuration: configuration
    )

    let sendTask = Task {
      await fixture.processor.send(
        "请慢慢说完",
        appContext: .init(identity: .penguin, tone: .gentle),
        mode: .localMock,
        requestID: "request-clear-race",
        clientTurnID: "turn-clear-race"
      )
    }
    try await Task.sleep(for: .milliseconds(220))
    let cleared = await fixture.processor.clear(
      requestID: "clear-race"
    )
    #expect(cleared.messages.isEmpty)

    let late = await sendTask.value
    #expect(late.messages.isEmpty)
    #expect(
      late.phase
        == .failed(
          requestID: "request-clear-race",
          failure: .cancelled
        )
        || late.phase
          == .failed(
            requestID: "request-clear-race",
            failure: .staleAuthority
          )
    )
    #expect(try await fixture.repository.current().messages.isEmpty)
  }

  @Test("Memory consent revocation invalidates stream and prompt index")
  func memoryRevocationInvalidatesLease() async throws {
    let configuration = ConversationRuntimeConfiguration(
      requestTimeout: 3,
      streamChunkDelay: 0.15
    )
    let authority = MutableChatAuthority(
      snapshot: chatAuthority(
        memoryEnabled: true,
        memoryRevision: revision(4)
      )
    )
    let fixture = try await makeFixture(
      authority: authority,
      transport: DeterministicMockChatTransport(
        behavior: .slowStream,
        configuration: configuration
      ),
      configuration: configuration
    )
    let memoryID = MemoryID("memory-1")

    let sendTask = Task {
      await fixture.processor.send(
        "还记得吗？",
        appContext: .init(
          identity: .penguin,
          tone: .gentle,
          selectedMemoryExcerpt: SelectedMemoryExcerpt(
            memoryID: memoryID,
            text: "今天我们经过了一段很长的路。"
          ),
          selectedMemoryRevision: revision(9)
        ),
        mode: .localMock,
        requestID: "request-memory",
        clientTurnID: "turn-memory"
      )
    }
    try await Task.sleep(for: .milliseconds(220))
    await authority.replace(
      chatAuthority(
        memoryEnabled: false,
        memoryRevision: revision(5)
      )
    )

    let final = await sendTask.value
    #expect(
      final.phase
        == .failed(
          requestID: "request-memory",
          failure: .staleAuthority
        )
    )
    let persisted = try await fixture.repository.current()
    #expect(persisted.contextIndex.isEmpty)
    #expect(persisted.messages.contains(where: { $0.role == .mori }) == false)
  }

  @Test("Real remote mode requires consent and never falls back to Mock transport")
  func remoteModeRequiresAuthorityAndProductionTransport() async throws {
    let realProfile = testProfile(mock: false)
    let storage = InMemoryConversationRepositoryStorage()
    let repository = try ConversationRepository(
      storage: storage,
      profile: realProfile,
      originDeviceID: "phone-chat",
      configuration: fastConfiguration
    )
    let authority = MutableChatAuthority(
      snapshot: chatAuthority(
        profile: realProfile,
        remoteEnabled: false
      )
    )
    let processor = try ConversationProcessor(
      profile: realProfile,
      repository: repository,
      authority: authority,
      transport: UnavailableRemoteChatTransport(),
      configuration: fastConfiguration
    )

    let final = await processor.send(
      "你好",
      appContext: .init(identity: .penguin, tone: .gentle),
      mode: .remote,
      requestID: "request-real",
      clientTurnID: "turn-real"
    )
    #expect(
      final.phase
        == .failed(
          requestID: "request-real",
          failure: .unauthorized
        )
    )
    #expect(final.messages.isEmpty)

    await authority.replace(
      chatAuthority(
        profile: realProfile,
        remoteEnabled: true
      )
    )
    let unavailable = await processor.send(
      "现在可以发送吗？",
      appContext: .init(identity: .penguin, tone: .gentle),
      mode: .remote,
      requestID: "request-real-enabled",
      clientTurnID: "turn-real-enabled"
    )
    #expect(
      unavailable.phase
        == .failed(
          requestID: "request-real-enabled",
          failure: .unavailable
        )
    )
    let persisted = try await repository.current()
    #expect(
      persisted.firstSendDisclosureVersion
        == MoriConsentKind.remoteChat.requiredDisclosureVersion
    )
    #expect(persisted.messages.map(\.role) == [.user])
  }

  private var fastConfiguration: ConversationRuntimeConfiguration {
    ConversationRuntimeConfiguration(
      requestTimeout: 1,
      streamChunkDelay: 0
    )
  }

  private func makeFixture(
    authority: MutableChatAuthority? = nil,
    transport: any ChatTransport = DeterministicMockChatTransport(
      configuration: ConversationRuntimeConfiguration(
        requestTimeout: 1,
        streamChunkDelay: 0
      )
    ),
    configuration: ConversationRuntimeConfiguration? = nil
  ) async throws -> ProcessorFixture {
    let profile = testProfile(mock: true)
    let actualConfiguration = configuration ?? fastConfiguration
    let storage = InMemoryConversationRepositoryStorage()
    let repository = try ConversationRepository(
      storage: storage,
      profile: profile,
      originDeviceID: "phone-chat",
      configuration: actualConfiguration
    )
    let actualAuthority =
      authority
      ?? MutableChatAuthority(
        snapshot: chatAuthority(profile: profile)
      )
    let audit = InMemoryConversationAuditRecorder()
    let processor = try ConversationProcessor(
      profile: profile,
      repository: repository,
      authority: actualAuthority,
      transport: transport,
      configuration: actualConfiguration,
      audit: audit
    )
    return ProcessorFixture(
      processor: processor,
      repository: repository,
      authority: actualAuthority,
      audit: audit
    )
  }

  private func chatAuthority(
    profile: RuntimeProfile? = nil,
    remoteEnabled: Bool = false,
    memoryEnabled: Bool = false,
    memoryRevision: LamportRevision? = nil
  ) -> ChatAuthoritySnapshot {
    let actualProfile = profile ?? testProfile(mock: true)
    return ChatAuthoritySnapshot(
      profile: actualProfile,
      remoteChatConsent: consent(
        kind: .remoteChat,
        enabled: remoteEnabled,
        revision: revision(2)
      ),
      memoryContextConsent: consent(
        kind: .memoryContext,
        enabled: memoryEnabled,
        revision: memoryRevision ?? revision(3)
      )
    )
  }

  private func consent(
    kind: MoriConsentKind,
    enabled: Bool,
    revision: LamportRevision
  ) -> MoriConsentRecord {
    MoriConsentRecord(
      enabled: enabled,
      disclosureVersion:
        enabled ? kind.requiredDisclosureVersion : 0,
      revision: revision,
      authorDevice: .phone
    )
  }

  private func testProfile(
    mock: Bool
  ) -> RuntimeProfile {
    let value = revision(1)
    let epoch = ProfileEpoch(value)
    return RuntimeProfile(
      id: ProfileID(mock ? "mock-chat" : "real"),
      epoch: epoch,
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("test-baseline"),
        revision: value
      ),
      source:
        mock
        ? .mock(
          scenarioID: MockScenarioID("mock1"),
          selectionEpoch: epoch
        )
        : .real
    )
  }

  private func revision(
    _ counter: UInt64
  ) -> LamportRevision {
    LamportRevision(
      counter: counter,
      originDeviceID: "phone"
    )
  }
}

private struct ProcessorFixture {
  let processor: ConversationProcessor
  let repository:
    ConversationRepository<
      InMemoryConversationRepositoryStorage
    >
  let authority: MutableChatAuthority
  let audit: InMemoryConversationAuditRecorder
}

private actor MutableChatAuthority: ChatAuthorityProviding {
  private var snapshot: ChatAuthoritySnapshot

  init(snapshot: ChatAuthoritySnapshot) {
    self.snapshot = snapshot
  }

  func currentChatAuthority() -> ChatAuthoritySnapshot {
    snapshot
  }

  func replace(_ snapshot: ChatAuthoritySnapshot) {
    self.snapshot = snapshot
  }
}

private actor ConversationStateObserver {
  private(set) var states: [ConversationPresentationState] = []

  func append(_ state: ConversationPresentationState) {
    states.append(state)
  }
}

private final class MutableMockChatTransport:
  ChatTransport, @unchecked Sendable
{
  let isolation: RuntimeServiceIsolation = .localOnly

  private let lock = NSLock()
  private var behavior: DeterministicMockChatBehavior
  private var requests: [ChatRequestEnvelopeV1] = []

  init(behavior: DeterministicMockChatBehavior) {
    self.behavior = behavior
  }

  func setBehavior(_ behavior: DeterministicMockChatBehavior) {
    lock.lock()
    self.behavior = behavior
    lock.unlock()
  }

  func capturedRequests() -> [ChatRequestEnvelopeV1] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }

  func stream(
    request: ChatRequestEnvelopeV1,
    lease: ChatAuthorityLease
  ) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
    lock.lock()
    requests.append(request)
    let behavior = behavior
    lock.unlock()
    return DeterministicMockChatTransport(
      behavior: behavior,
      configuration: ConversationRuntimeConfiguration(
        requestTimeout: 1,
        streamChunkDelay: 0
      )
    ).stream(request: request, lease: lease)
  }
}
