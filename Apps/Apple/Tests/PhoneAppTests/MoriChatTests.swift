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
