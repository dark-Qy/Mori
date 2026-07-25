import Domain
import Foundation
import MoriDomain
import MoriRuntime
import Persistence
import XCTest

@testable import WatchCompanion

final class MoriChatTests: XCTestCase {
  func testUITestingKeepsNudgeHiddenUnlessForced() {
    let suiteName = "MoriChatTests.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removePersistentDomain(forName: suiteName) }

    let hidden = MoriChatNudgePolicy(
      arguments: ["WatchCompanion", "-UITesting"],
      defaults: suite,
      calendar: utcCalendar()
    )
    let visible = MoriChatNudgePolicy(
      arguments: ["WatchCompanion", "-UITesting", "--chat-nudge=visible"],
      defaults: suite,
      calendar: utcCalendar()
    )
    let date = Date(timeIntervalSince1970: 1_760_000_000)

    XCTAssertNil(hidden.nextNudge(at: date))
    XCTAssertNotNil(visible.nextNudge(at: date))
  }

  func testNudgeAppearsAtMostOncePerEligibleDay() throws {
    let suiteName = "MoriChatTests.\(UUID().uuidString)"
    let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let policy = MoriChatNudgePolicy(
      arguments: ["WatchCompanion"],
      defaults: suite,
      calendar: utcCalendar()
    )
    let start = Date(timeIntervalSince1970: 1_760_000_000)

    let eligible = try XCTUnwrap(
      (0..<14)
        .map { start.addingTimeInterval(Double($0) * 86_400) }
        .first { policy.nextNudge(at: $0) != nil }
    )

    XCTAssertNil(policy.nextNudge(at: eligible))
  }

  @MainActor
  func testChatClientUsesBoundedTypedContract() async throws {
    MoriChatURLProtocolStub.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MoriChatURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = MoriChatAIClient(
      configuration: WeeklyMemoryAIRuntimeConfiguration(
        baseURL: try XCTUnwrap(URL(string: "https://social.example"))
      ),
      credentialProvider: StaticChatCredentialProvider(token: "runtime-token"),
      session: session
    )
    var messages = (0..<13).map {
      MoriChatMessage(
        author: $0.isMultiple(of: 2) ? .mori : .owner,
        text: "第 \($0) 条消息"
      )
    }
    messages.append(MoriChatMessage(author: .owner, text: "今天有点累"))

    let reply = await client.reply(to: messages, personality: .moriCore)

    XCTAssertEqual(reply.text, "我在这里，慢慢听你说。")
    XCTAssertEqual(reply.source, .upstream)
    let request = try XCTUnwrap(MoriChatURLProtocolStub.recordedRequest())
    XCTAssertEqual(request.url?.path, "/ai/v1/chat/reply")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"),
      "Bearer runtime-token"
    )
    let body = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        as? [String: Any]
    )
    XCTAssertEqual(Set(body.keys), ["request_id", "locale", "messages", "personality"])
    XCTAssertEqual(reply.speechRequestID, body["request_id"] as? String)
    XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 11)
    XCTAssertEqual(
      (body["messages"] as? [[String: Any]])?.first?["role"] as? String,
      "user"
    )
    XCTAssertEqual(
      (body["messages"] as? [[String: Any]])?.last?["content"] as? String,
      "今天有点累"
    )
    XCTAssertEqual(
      (body["personality"] as? [String: Any])?["is_personalized"] as? Bool,
      false
    )
  }

  @MainActor
  func testChatClientFailsClosedWithoutCredential() async throws {
    MoriChatURLProtocolStub.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MoriChatURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = MoriChatAIClient(
      configuration: WeeklyMemoryAIRuntimeConfiguration(
        baseURL: try XCTUnwrap(URL(string: "https://social.example"))
      ),
      credentialProvider: StaticChatCredentialProvider(token: nil),
      session: session
    )

    let reply = await client.reply(
      to: [MoriChatMessage(author: .owner, text: "今天有点累")],
      personality: .moriCore
    )

    XCTAssertEqual(reply.source, .fallback)
    XCTAssertTrue(MoriChatURLProtocolStub.recordedRequest() == nil)
  }

  @MainActor
  func testDirectStepFunChatClientUsesAICompletionContract() async throws {
    MoriStepFunChatURLProtocolStub.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MoriStepFunChatURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = DirectMoriStepFunChatAIClient(
      endpoint: try XCTUnwrap(
        URL(string: "https://api.stepfun.com/v1/chat/completions")
      ),
      credentialProvider: StaticChatCredentialProvider(token: "provider-token"),
      session: session
    )

    let reply = await client.reply(
      to: [MoriChatMessage(author: .owner, text: "今天完成了一件很难的事")],
      personality: .moriCore
    )

    XCTAssertEqual(reply.text, "真的很棒，我想听你再讲一点。")
    XCTAssertEqual(reply.source, .upstream)
    XCTAssertNil(reply.speechRequestID)
    let request = try XCTUnwrap(MoriStepFunChatURLProtocolStub.recordedRequest())
    XCTAssertEqual(request.url?.path, "/v1/chat/completions")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"),
      "Bearer provider-token"
    )
    let body = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        as? [String: Any]
    )
    XCTAssertEqual(body["model"] as? String, "step-3.5-flash")
    XCTAssertEqual(body["stream"] as? Bool, false)
    XCTAssertNil(body["max_tokens"])
    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.first?["role"] as? String, "system")
    XCTAssertTrue(
      (messages.first?["content"] as? String)?.contains("你是 Mori") == true
    )
    XCTAssertEqual(messages.last?["role"] as? String, "user")
    XCTAssertEqual(messages.last?["content"] as? String, "今天完成了一件很难的事")
  }

  @MainActor
  func testDirectStepFunChatClientDoesNotResendBlockedHistory() async throws {
    MoriStepFunChatURLProtocolStub.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MoriStepFunChatURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = DirectMoriStepFunChatAIClient(
      endpoint: try XCTUnwrap(
        URL(string: "https://api.stepfun.com/v1/chat/completions")
      ),
      credentialProvider: StaticChatCredentialProvider(token: "provider-token"),
      session: session
    )
    let credential =
      "Authorization: Bearer " + String(repeating: "a", count: 32)

    let blockedReply = await client.reply(
      to: [MoriChatMessage(author: .owner, text: credential)],
      personality: .moriCore
    )
    XCTAssertEqual(blockedReply.source, .fallback)
    XCTAssertNil(MoriStepFunChatURLProtocolStub.recordedRequest())

    _ = await client.reply(
      to: [
        MoriChatMessage(author: .owner, text: credential),
        MoriChatMessage(author: .mori, text: blockedReply.text),
        MoriChatMessage(author: .owner, text: "好的，我们聊聊彩虹"),
      ],
      personality: .moriCore
    )

    let request = try XCTUnwrap(MoriStepFunChatURLProtocolStub.recordedRequest())
    let bodyData = try XCTUnwrap(request.httpBody)
    let bodyText = try XCTUnwrap(String(data: bodyData, encoding: .utf8))
    XCTAssertFalse(bodyText.contains(credential))
    let body = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    )
    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.last?["role"] as? String, "user")
    XCTAssertEqual(messages.last?["content"] as? String, "好的，我们聊聊彩虹")
  }

  @MainActor
  func testMock1UsesDirectAIWhenExplicitlyEnabledForUITesting() async {
    let gateway = RecordingMoriChatClient(
      reply: MoriChatReply(text: "gateway", source: .upstream)
    )
    let direct = RecordingMoriChatClient(
      reply: MoriChatReply(text: "direct-ai", source: .upstream)
    )
    let store = PhoneAppStore(
      arguments: [
        "WatchCompanion",
        "-UITesting",
        "--mock-scenario=mock1",
        "--enable-chat-ai",
      ],
      chatReplying: gateway,
      debugDirectChatReplying: direct
    )

    let reply = await store.replyToMoriChat(
      messages: [MoriChatMessage(author: .owner, text: "这是一条真实 AI 测试")]
    )

    XCTAssertEqual(reply.text, "direct-ai")
    XCTAssertEqual(direct.receivedMessages.count, 1)
    XCTAssertTrue(gateway.receivedMessages.isEmpty)
  }

  @MainActor
  func testMock1UITestingKeepsDirectAIDisabledWithoutExplicitFlag() async {
    let local = RecordingMoriChatClient(
      reply: MoriChatReply(text: "local", source: .fallback)
    )
    let direct = RecordingMoriChatClient(
      reply: MoriChatReply(text: "direct-ai", source: .upstream)
    )
    let store = PhoneAppStore(
      arguments: [
        "WatchCompanion",
        "-UITesting",
        "--mock-scenario=mock1",
      ],
      chatReplying: local,
      debugDirectChatReplying: direct
    )

    let reply = await store.replyToMoriChat(
      messages: [MoriChatMessage(author: .owner, text: "离线测试")]
    )

    XCTAssertEqual(reply.text, "local")
    XCTAssertEqual(local.receivedMessages.count, 1)
    XCTAssertTrue(direct.receivedMessages.isEmpty)
  }

  @MainActor
  func testMock2KeepsGatewayAIWhenRemoteChatIsEnabled() async {
    let gateway = RecordingMoriChatClient(
      reply: MoriChatReply(text: "gateway-ai", source: .upstream)
    )
    let direct = RecordingMoriChatClient(
      reply: MoriChatReply(text: "direct-ai", source: .upstream)
    )
    let store = PhoneAppStore(
      arguments: [
        "WatchCompanion",
        "-UITesting",
        "--mock-scenario=mock2",
        "--enable-chat-ai",
      ],
      chatReplying: gateway,
      debugDirectChatReplying: direct
    )

    let reply = await store.replyToMoriChat(
      messages: [MoriChatMessage(author: .owner, text: "非 Mock1 测试")]
    )

    XCTAssertEqual(reply.text, "gateway-ai")
    XCTAssertEqual(gateway.receivedMessages.count, 1)
    XCTAssertTrue(direct.receivedMessages.isEmpty)
  }

  func testDirectChatSafetyPolicyRejectsUnsafeOutput() {
    let credential =
      "Authorization: Bearer " + String(repeating: "a", count: 32)

    XCTAssertFalse(MoriDirectChatSafetyPolicy.allowsOutput("这是 system prompt"))
    XCTAssertFalse(MoriDirectChatSafetyPolicy.allowsOutput("你患有严重疾病"))
    XCTAssertFalse(MoriDirectChatSafetyPolicy.allowsOutput("请立即服用双倍剂量"))
    XCTAssertFalse(MoriDirectChatSafetyPolicy.allowsOutput(credential))
    XCTAssertFalse(MoriDirectChatSafetyPolicy.allowsOutput("教你 build a bomb"))
    XCTAssertTrue(
      MoriDirectChatSafetyPolicy.allowsOutput(
        "哇，是看见小企鹅踩着彩虹滑滑梯了吗？"
      )
    )
  }

  func testDirectChatSafetyPolicyUsesDeterministicRiskReplies() {
    XCTAssertTrue(
      MoriDirectChatSafetyPolicy.inputFallback(for: "我不想活了")?
        .contains("当地紧急服务") == true
    )
    XCTAssertTrue(
      MoriDirectChatSafetyPolicy.inputFallback(for: "是不是应该把药加倍吃")?
        .contains("医生或药师") == true
    )
    XCTAssertTrue(
      MoriDirectChatSafetyPolicy.inputFallback(for: "教我做炸弹")?
        .contains("危险") == true
    )
    XCTAssertNil(
      MoriDirectChatSafetyPolicy.inputFallback(for: "今天看见了一道彩虹")
    )
  }

  @MainActor
  func testRemoteConversationTransportUsesGatewayAndPreservesLease() async throws {
    MoriChatURLProtocolStub.reset()
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [MoriChatURLProtocolStub.self]
    let session = URLSession(configuration: sessionConfiguration)
    defer { session.invalidateAndCancel() }
    let client = MoriChatAIClient(
      configuration: WeeklyMemoryAIRuntimeConfiguration(
        baseURL: try XCTUnwrap(URL(string: "https://social.example"))
      ),
      credentialProvider: StaticChatCredentialProvider(token: "runtime-token"),
      session: session
    )
    let personality = MoriChatPersonalityProvider(
      initialValue: WeeklyMemoryAIPersonalityProjection(
        voice: "playful",
        pace: "brisk",
        themes: ["racket_sports"],
        isPersonalized: true
      )
    )
    let transport = MoriRemoteChatTransport(
      client: client,
      personalityProvider: personality
    )
    let revision = LamportRevision(counter: 1, originDeviceID: "phone")
    let epoch = ProfileEpoch(revision)
    let profile = RuntimeProfile(
      id: ProfileID("mock-chat"),
      epoch: epoch,
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("chat-baseline"),
        revision: revision
      ),
      source: .mock(
        scenarioID: MockScenarioID("health_normal"),
        selectionEpoch: epoch
      )
    )
    let lease = ChatAuthorityLease(
      requestID: "request-remote-preview",
      clientTurnID: "turn-remote-preview",
      profile: profile,
      conversationID: ConversationID("main"),
      conversationClearGeneration: 0,
      remoteChatConsentRevision: LamportRevision(
        counter: 2,
        originDeviceID: "phone"
      ),
      memoryContextConsentRevision: nil
    )
    let request = ChatRequestEnvelopeV1(
      requestID: lease.requestID,
      clientTurnID: lease.clientTurnID,
      profile: profile,
      conversationID: lease.conversationID,
      conversationClearGeneration: lease.conversationClearGeneration,
      remoteChatConsentRevision: lease.remoteChatConsentRevision,
      memoryContextConsentRevision: nil,
      explicitMessage: "你知道我最近在做什么吗？",
      recentMessages: [
        ChatMessageV1(
          recordID: ConversationRecordID("previous-user"),
          role: .user,
          content: "我最近常打网球。"
        ),
        ChatMessageV1(
          recordID: ConversationRecordID("previous-mori"),
          role: .mori,
          content: "那听起来挺开心的。"
        ),
      ],
      appContext: ChatAppContextV1(
        identity: .penguin,
        tone: .gentle,
        approvedEventIDs: [],
        selectedMemoryExcerpt: nil
      )
    )

    var events: [ChatStreamEvent] = []
    for try await event in transport.stream(request: request, lease: lease) {
      events.append(event)
    }

    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events.first, .chunk("我在这里，慢慢听你说。"))
    guard case .completed(let response) = events.last else {
      return XCTFail("Expected a completed response envelope")
    }
    XCTAssertEqual(response.requestID, lease.requestID)
    XCTAssertEqual(response.clientTurnID, lease.clientTurnID)
    XCTAssertEqual(response.profileID, lease.profile.id)
    XCTAssertEqual(response.replyText, "我在这里，慢慢听你说。")

    let captured = try XCTUnwrap(MoriChatURLProtocolStub.recordedRequest())
    let body = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: captured.httpBody ?? Data())
        as? [String: Any]
    )
    XCTAssertEqual(body["request_id"] as? String, lease.requestID)
    XCTAssertEqual(
      (body["messages"] as? [[String: Any]])?.last?["content"] as? String,
      request.explicitMessage
    )
    XCTAssertEqual(
      (body["personality"] as? [String: Any])?["is_personalized"] as? Bool,
      true
    )
  }

  func testBundledCredentialReadsTrimmedToken() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let tokenURL = directory.appending(path: "MoriGatewayToken.private")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try Data("  bundled-token\n".utf8).write(to: tokenURL, options: .atomic)

    let provider = BundledWeeklyMemoryAICredentialProvider(resourceURL: tokenURL)

    XCTAssertEqual(provider.bearerToken(), "bundled-token")
  }

  @MainActor
  func testSpeechClientUsesGatewayContractAndAcceptsMP3() async throws {
    MoriSpeechURLProtocolStub.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MoriSpeechURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = MoriSpeechAIClient(
      configuration: WeeklyMemoryAIRuntimeConfiguration(
        baseURL: try XCTUnwrap(URL(string: "https://social.example"))
      ),
      credentialProvider: StaticChatCredentialProvider(token: "runtime-token"),
      session: session
    )

    let audio = try await client.synthesize(
      requestID: "speech-request-001",
      text: nil
    )

    XCTAssertEqual(audio, Data("ID3-test-audio".utf8))
    let request = try XCTUnwrap(MoriSpeechURLProtocolStub.recordedRequest())
    XCTAssertEqual(request.url?.path, "/ai/v1/audio/speech")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"),
      "Bearer runtime-token"
    )
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Accept"),
      "audio/mpeg"
    )
    let body = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        as? [String: Any]
    )
    XCTAssertEqual(Set(body.keys), ["request_id"])
    XCTAssertEqual(body["request_id"] as? String, "speech-request-001")
  }

  @MainActor
  func testSpeechClientFailsClosedWithoutGatewayCredential() async throws {
    MoriSpeechURLProtocolStub.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MoriSpeechURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = MoriSpeechAIClient(
      configuration: WeeklyMemoryAIRuntimeConfiguration(
        baseURL: try XCTUnwrap(URL(string: "https://social.example"))
      ),
      credentialProvider: StaticChatCredentialProvider(token: nil),
      session: session
    )

    do {
      _ = try await client.synthesize(
        requestID: "speech-request-unauthorized",
        text: nil
      )
      XCTFail("Expected missing gateway credentials to fail closed")
    } catch {
      XCTAssertEqual(error as? MoriSpeechFailure, .unauthorized)
    }
    XCTAssertNil(MoriSpeechURLProtocolStub.recordedRequest())
  }

  @MainActor
  func testDirectStepFunSpeechClientSendsReplyTextAndAcceptsMP3() async throws {
    MoriSpeechURLProtocolStub.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MoriSpeechURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = DirectMoriStepFunSpeechAIClient(
      endpoint: try XCTUnwrap(
        URL(string: "https://api.stepfun.com/v1/audio/speech")
      ),
      credentialProvider: StaticChatCredentialProvider(token: "provider-token"),
      session: session
    )

    let audio = try await client.synthesize(
      requestID: nil,
      text: "我在这里，慢慢听你说。"
    )

    XCTAssertEqual(audio, Data("ID3-test-audio".utf8))
    let request = try XCTUnwrap(MoriSpeechURLProtocolStub.recordedRequest())
    XCTAssertEqual(request.url?.absoluteString, "https://api.stepfun.com/v1/audio/speech")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"),
      "Bearer provider-token"
    )
    let body = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        as? [String: Any]
    )
    XCTAssertEqual(body["model"] as? String, "stepaudio-2.5-tts")
    XCTAssertEqual(body["voice"] as? String, "ruanmengnvsheng")
    XCTAssertEqual(body["input"] as? String, "我在这里，慢慢听你说。")
    XCTAssertEqual(body["response_format"] as? String, "mp3")
    XCTAssertNotNil(body["instruction"] as? String)
    XCTAssertNil(body["request_id"])
  }

  @MainActor
  func testDirectStepFunSpeechClientFailsClosedWithoutProviderCredential()
    async throws
  {
    MoriSpeechURLProtocolStub.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MoriSpeechURLProtocolStub.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = DirectMoriStepFunSpeechAIClient(
      endpoint: try XCTUnwrap(
        URL(string: "https://api.stepfun.com/v1/audio/speech")
      ),
      credentialProvider: StaticChatCredentialProvider(token: nil),
      session: session
    )

    do {
      _ = try await client.synthesize(requestID: nil, text: "测试")
      XCTFail("Expected missing provider credentials to fail closed")
    } catch {
      XCTAssertEqual(error as? MoriSpeechFailure, .unauthorized)
    }
    XCTAssertNil(MoriSpeechURLProtocolStub.recordedRequest())
  }

  @MainActor
  func testDebugSpeechRouterUsesDirectTextThenFallsBackToGatewayRequestID()
    async throws
  {
    let direct = RecordingMoriSpeechSynthesizer(audio: Data("direct".utf8))
    let gateway = RecordingMoriSpeechSynthesizer(audio: Data("gateway".utf8))
    let router = DebugMoriSpeechRouter(
      directSynthesizer: direct,
      gatewaySynthesizer: gateway
    )

    let directAudio = try await router.synthesize(
      requestID: nil,
      text: "Mock 1 reply"
    )
    let gatewayAudio = try await router.synthesize(
      requestID: "gateway-speech-request",
      text: nil
    )

    XCTAssertEqual(directAudio, Data("direct".utf8))
    XCTAssertEqual(gatewayAudio, Data("gateway".utf8))
    XCTAssertEqual(
      direct.invocations,
      [.init(requestID: nil, text: "Mock 1 reply")]
    )
    XCTAssertEqual(
      gateway.invocations,
      [.init(requestID: "gateway-speech-request", text: nil)]
    )
  }

  @MainActor
  func testCommittedConversationReplyTriggersSpeechOnce() async {
    let speech = RecordingMoriSpeechPlaybackCoordinator()
    let store = PhoneAppStore(
      arguments: [
        "WatchCompanion",
        "-UITesting",
        "--mock-scenario=health_normal",
      ],
      chatSpeechCoordinator: speech
    )
    await store.start()

    await store.sendConversationMessage(
      "今天想聊聊天",
      requestID: "chat-speech-request-001"
    )

    XCTAssertEqual(speech.spoken.count, 1)
    XCTAssertEqual(speech.spoken.first?.speechRequestID, "chat-speech-request-001")
  }

  @MainActor
  func testConversationReplyDoesNotSpeakAfterLeavingMoriTab() async {
    let speech = RecordingMoriSpeechPlaybackCoordinator()
    let store = PhoneAppStore(
      arguments: [
        "WatchCompanion",
        "-UITesting",
        "--mock-scenario=health_normal",
      ],
      chatSpeechCoordinator: speech
    )
    await store.start()
    store.selectedTab = .today

    await store.sendConversationMessage(
      "今天想聊聊天",
      requestID: "chat-hidden-speech-request-001"
    )

    XCTAssertTrue(speech.spoken.isEmpty)
  }

  @MainActor
  func testMock1LocalReplyTriggersDirectSpeechText() async {
    let speech = RecordingMoriSpeechPlaybackCoordinator()
    let store = PhoneAppStore(
      arguments: [
        "WatchCompanion",
        "-UITesting",
        "--mock-scenario=mock1",
      ],
      chatSpeechCoordinator: speech
    )
    await store.start()
    let reply = await store.replyToMoriChat(
      messages: [MoriChatMessage(author: .owner, text: "今天想聊聊天")]
    )

    store.speakMoriChatReply(reply)

    XCTAssertEqual(speech.spoken.count, 1)
    XCTAssertNil(speech.spoken.first?.speechRequestID)
    XCTAssertEqual(speech.spoken.first?.text, reply.text)
  }

  func testChatHabitExtractorKeepsOnlyTypedStablePreferences() {
    let message = MoriChatMessage(
      id: UUID(uuidString: "D21997C4-0A58-4E4B-AF7A-57D22F7A7060")!,
      author: .owner,
      text: "我周末经常打网球，也喜欢游泳。以后回复短一点。"
    )

    let signals = ChatPersonalizationEvidenceFactory().make(from: message)

    XCTAssertTrue(
      signals.contains {
        guard case .explicitActivityPreference(.tennis, 0.8, _) = $0 else {
          return false
        }
        return true
      }
    )
    XCTAssertTrue(
      signals.contains {
        guard case .explicitActivityPreference(.swimming, 0.8, _) = $0 else {
          return false
        }
        return true
      }
    )
    XCTAssertTrue(
      signals.contains {
        guard case .explicitInterest(.racketSports, 0.8, _) = $0 else {
          return false
        }
        return true
      }
    )
    XCTAssertTrue(
      signals.contains {
        guard case .explicitExpressionPreference(.concise, _) = $0 else {
          return false
        }
        return true
      }
    )
    XCTAssertTrue(
      ChatPersonalizationEvidenceFactory()
        .make(from: MoriChatMessage(author: .owner, text: "今天有点累"))
        .isEmpty
    )
  }

  @MainActor
  func testChatHabitIsPersistedWithoutStoringConversationText() async throws {
    let repository = PersonalizationRepository(
      storage: InMemoryPersonalizationStorage()
    )
    let store = PhoneAppStore(
      arguments: ["WatchCompanion", "-UITesting", "--mock-scenario=health_normal"],
      chatReplying: LocalMoriChatClient(),
      personalizationRepository: repository
    )

    _ = await store.replyToMoriChat(
      messages: [
        MoriChatMessage(author: .owner, text: "我周末经常游泳")
      ]
    )

    let state = try await repository.state()
    XCTAssertTrue(
      state.memories.contains {
        guard case .activity(.swimming) = $0.subject else { return false }
        return true
      }
    )
    XCTAssertEqual(state.owner.activityAffinities[.swimming] ?? 0, 0.72, accuracy: 0.001)
    XCTAssertFalse(
      state.memories.flatMap(\.evidence).map(\.id)
        .contains(where: { $0.contains("我周末经常游泳") })
    )
  }

  private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
}

private struct StaticChatCredentialProvider: WeeklyMemoryAICredentialProviding {
  let token: String?

  func bearerToken() -> String? {
    token
  }
}

@MainActor
private final class RecordingMoriChatClient: MoriChatReplying {
  let cannedReply: MoriChatReply
  private(set) var receivedMessages: [[MoriChatMessage]] = []

  init(reply: MoriChatReply) {
    cannedReply = reply
  }

  func reply(
    to messages: [MoriChatMessage],
    personality _: WeeklyMemoryAIPersonalityProjection
  ) async -> MoriChatReply {
    receivedMessages.append(messages)
    return cannedReply
  }
}

@MainActor
private final class RecordingMoriSpeechSynthesizer: MoriSpeechSynthesizing {
  struct Invocation: Equatable {
    let requestID: String?
    let text: String?
  }

  let audio: Data
  private(set) var invocations: [Invocation] = []

  init(audio: Data) {
    self.audio = audio
  }

  func synthesize(requestID: String?, text: String?) async throws -> Data {
    invocations.append(.init(requestID: requestID, text: text))
    return audio
  }
}

@MainActor
private final class RecordingMoriSpeechPlaybackCoordinator:
  MoriSpeechPlaybackCoordinating
{
  struct SpokenValue: Equatable {
    let messageID: String
    let speechRequestID: String?
    let text: String?
  }

  private(set) var spoken: [SpokenValue] = []

  func speak(
    messageID: String,
    speechRequestID: String?,
    text: String?
  ) {
    spoken.append(
      SpokenValue(
        messageID: messageID,
        speechRequestID: speechRequestID,
        text: text
      )
    )
  }

  func stop() {}
}

private final class MoriChatURLProtocolStub: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) private static var capturedRequest: URLRequest?
  private static let lock = NSLock()

  static func reset() {
    lock.withLock {
      capturedRequest = nil
    }
  }

  static func recordedRequest() -> URLRequest? {
    lock.withLock { capturedRequest }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    do {
      let captured = try Self.capture(request)
      Self.lock.withLock {
        Self.capturedRequest = captured
      }
      let requestBody = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: captured.httpBody ?? Data())
          as? [String: Any]
      )
      let responseBody: [String: Any] = [
        "request_id": try XCTUnwrap(requestBody["request_id"] as? String),
        "reply": "我在这里，慢慢听你说。",
        "source": "upstream",
        "fallback_reason": NSNull(),
        "passed_output_checks": true,
      ]
      let data = try JSONSerialization.data(withJSONObject: responseBody)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(captured.url),
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

  private static func capture(_ request: URLRequest) throws -> URLRequest {
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
        throw stream.streamError ?? URLError(.cannotDecodeContentData)
      }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    var captured = request
    captured.httpBodyStream = nil
    captured.httpBody = data
    return captured
  }
}

private final class MoriStepFunChatURLProtocolStub: URLProtocol,
  @unchecked Sendable
{
  nonisolated(unsafe) private static var capturedRequest: URLRequest?
  private static let lock = NSLock()

  static func reset() {
    lock.withLock {
      capturedRequest = nil
    }
  }

  static func recordedRequest() -> URLRequest? {
    lock.withLock { capturedRequest }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    do {
      let captured = try Self.capture(request)
      Self.lock.withLock {
        Self.capturedRequest = captured
      }
      let responseBody: [String: Any] = [
        "id": "chat-completion-test",
        "model": "step-3.5-flash",
        "choices": [
          [
            "index": 0,
            "message": [
              "role": "assistant",
              "content": "真的很棒，我想听你再讲一点。",
            ],
            "finish_reason": "stop",
          ]
        ],
      ]
      let data = try JSONSerialization.data(withJSONObject: responseBody)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(captured.url),
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

  private static func capture(_ request: URLRequest) throws -> URLRequest {
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
        throw stream.streamError ?? URLError(.cannotDecodeContentData)
      }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    var captured = request
    captured.httpBodyStream = nil
    captured.httpBody = data
    return captured
  }
}

private final class MoriSpeechURLProtocolStub: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) private static var capturedRequest: URLRequest?
  private static let lock = NSLock()

  static func reset() {
    lock.withLock {
      capturedRequest = nil
    }
  }

  static func recordedRequest() -> URLRequest? {
    lock.withLock { capturedRequest }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    do {
      let captured = try Self.capture(request)
      Self.lock.withLock {
        Self.capturedRequest = captured
      }
      let response = HTTPURLResponse(
        url: try XCTUnwrap(captured.url),
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "audio/mpeg"]
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data("ID3-test-audio".utf8))
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}

  private static func capture(_ request: URLRequest) throws -> URLRequest {
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
        throw stream.streamError ?? URLError(.cannotDecodeContentData)
      }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    var captured = request
    captured.httpBodyStream = nil
    captured.httpBody = data
    return captured
  }
}
