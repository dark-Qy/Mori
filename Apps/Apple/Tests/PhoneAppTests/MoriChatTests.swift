import Domain
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

    XCTAssertEqual(reply, MoriChatReply(text: "我在这里，慢慢听你说。", source: .upstream))
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
