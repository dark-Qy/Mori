#if DEBUG
  import CryptoKit
  import Foundation
  import MoriRuntime
  import Testing

  @Suite("Debug localhost paired relay")
  struct DebugLocalhostExperienceRelayTests {
    @Test("Configuration requires UI testing and a private strict loopback control file")
    func configurationBoundary() throws {
      let fixture = try RelayControlFixture()
      defer { fixture.remove() }

      #expect(
        throws: DebugLocalhostExperienceRelayError.uiTestingRequired
      ) {
        try DebugLocalhostExperienceRelayConfiguration(
          controlFileURL: fixture.url,
          role: .iPhone,
          launchArguments: ["App"]
        )
      }

      let configuration =
        try DebugLocalhostExperienceRelayConfiguration
        .loadFromLaunchArguments([
          "App",
          "-UITesting",
          "--mori-experience-relay-control-file=\(fixture.url.path)",
          "--mori-experience-relay-role=watch",
        ])
      #expect(configuration.baseURL.absoluteString == "http://127.0.0.1:49152")
      #expect(configuration.runID == fixture.runID)
      #expect(configuration.role == .watch)

      try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: fixture.url.path
      )
      #expect(
        throws:
          DebugLocalhostExperienceRelayError
          .insecureControlFilePermissions
      ) {
        try DebugLocalhostExperienceRelayConfiguration(
          controlFileURL: fixture.url,
          role: .iPhone,
          launchArguments: ["App", "-UITesting"]
        )
      }
    }

    @Test("Configuration rejects unknown metadata non-loopback hosts and weak tokens")
    func invalidControlMetadata() throws {
      for override in [
        ["host": "localhost"],
        ["token": String(repeating: "a", count: 62)],
        ["maximumBodyBytes": "1024"],
        ["extra": "field"],
      ] {
        let fixture = try RelayControlFixture(overrides: override)
        defer { fixture.remove() }
        #expect(throws: (any Error).self) {
          try DebugLocalhostExperienceRelayConfiguration(
            controlFileURL: fixture.url,
            role: .iPhone,
            launchArguments: ["App", "-UITesting"]
          )
        }
      }
    }

    @Test("Submit sends opaque bounded bytes and verifies acknowledgement digest")
    func submitRequest() async throws {
      let fixture = try RelayControlFixture()
      defer { fixture.remove() }
      let acknowledgement = Data("opaque-ack".utf8)
      let requester = RecordingRelayRequester(responses: [
        DebugLocalhostExperienceRelayHTTPResponse(
          statusCode: 200,
          headers: [
            "X-Mori-Acknowledgement-SHA256": digest(acknowledgement)
          ],
          body: acknowledgement
        )
      ])
      let client = DebugLocalhostExperienceRelayClient(
        configuration: try fixture.configuration(role: .iPhone),
        requester: requester
      )
      let transferID = try #require(
        UUID(uuidString: "0f813aa1-a244-4f41-ae1e-a75b305c86f7")
      )
      let body = Data("opaque-transfer".utf8)

      let response = try await client.submit(
        channel: .experience,
        body: body,
        transferID: transferID
      )

      #expect(response == acknowledgement)
      let requests = await requester.recordedRequests()
      let request = try #require(requests.first)
      #expect(request.method == .post)
      #expect(request.path == "/v1/submit/experience/iphone")
      #expect(request.body == body)
      #expect(
        request.headers["X-Mori-Transfer-ID"]
          == transferID.uuidString.lowercased()
      )
      #expect(request.headers["X-Mori-Transfer-SHA256"] == digest(body))
      #expect(request.headers["Authorization"] == "Bearer \(fixture.token)")
      #expect(request.headers.values.contains(String(decoding: body, as: UTF8.self)) == false)
    }

    @Test("Oversized payloads fail before transport and malformed acknowledgements fail closed")
    func payloadAndResponseBounds() async throws {
      let fixture = try RelayControlFixture()
      defer { fixture.remove() }
      let requester = RecordingRelayRequester(responses: [])
      let client = DebugLocalhostExperienceRelayClient(
        configuration: try fixture.configuration(role: .iPhone),
        requester: requester
      )
      let oversized = Data(
        repeating: 0,
        count:
          DebugLocalhostExperienceRelayConfiguration.maximumBodyBytes + 1
      )
      await #expect(
        throws:
          DebugLocalhostExperienceRelayError.oversized(
            actualBytes: oversized.count,
            maximumBytes:
              DebugLocalhostExperienceRelayConfiguration.maximumBodyBytes
          )
      ) {
        try await client.submit(channel: .experience, body: oversized)
      }
      #expect(await requester.recordedRequests().isEmpty)

      let malformedRequester = RecordingRelayRequester(responses: [
        DebugLocalhostExperienceRelayHTTPResponse(
          statusCode: 200,
          headers: [
            "X-Mori-Acknowledgement-SHA256": String(repeating: "0", count: 64)
          ],
          body: Data("ack".utf8)
        )
      ])
      let malformedClient = DebugLocalhostExperienceRelayClient(
        configuration: try fixture.configuration(role: .iPhone),
        requester: malformedRequester
      )
      await #expect(
        throws: DebugLocalhostExperienceRelayError.malformedResponse
      ) {
        try await malformedClient.submit(
          channel: .experience,
          body: Data("body".utf8)
        )
      }
    }

    @Test("URL session transport refuses redirects before forwarding opaque bytes")
    func redirectIsRejected() async throws {
      let fixture = try RelayControlFixture()
      defer { fixture.remove() }
      RedirectingRelayURLProtocolStub.reset()
      let sessionConfiguration = URLSessionConfiguration.ephemeral
      sessionConfiguration.protocolClasses = [
        RedirectingRelayURLProtocolStub.self
      ]
      let client = DebugLocalhostExperienceRelayClient(
        configuration: try fixture.configuration(
          role: .iPhone,
          requestTimeout: 0.1
        ),
        requester:
          URLSessionDebugLocalhostExperienceRelayHTTPRequester(
            configuration: sessionConfiguration
          )
      )

      await #expect(throws: (any Error).self) {
        try await client.submit(
          channel: .experience,
          body: Data("must-stay-local".utf8)
        )
      }
      let requestedURLs = RedirectingRelayURLProtocolStub.requestedURLs()
      #expect(requestedURLs.count == 1)
      #expect(requestedURLs.first?.host == "127.0.0.1")
    }

    @Test("Peer pump polls independently and acknowledges the exact transfer")
    func peerPump() async throws {
      let fixture = try RelayControlFixture()
      defer { fixture.remove() }
      let transferID = try #require(
        UUID(uuidString: "162d8285-f7f7-4b81-bdf0-52470106156c")
      )
      let transfer = Data("preference-state".utf8)
      let acknowledgement = Data("merged-state".utf8)
      let requester = RecordingRelayRequester(responses: [
        DebugLocalhostExperienceRelayHTTPResponse(
          statusCode: 200,
          headers: [
            "X-Mori-Transfer-ID": transferID.uuidString.lowercased(),
            "X-Mori-Transfer-SHA256": digest(transfer),
            "X-Mori-Sender-Role": "iphone",
          ],
          body: transfer
        ),
        DebugLocalhostExperienceRelayHTTPResponse(statusCode: 204),
      ])
      let client = DebugLocalhostExperienceRelayClient(
        configuration: try fixture.configuration(role: .watch),
        requester: requester
      )
      let pump = DebugLocalhostExperienceRelayPeerPump(client: client)

      let didPump = try await pump.pumpOnce(channel: .preferences) { body in
        guard body == transfer else {
          throw DebugLocalhostExperienceRelayError.malformedResponse
        }
        return acknowledgement
      }
      #expect(didPump)

      let requests = await requester.recordedRequests()
      #expect(
        requests.map(\.path) == [
          "/v1/poll/preferences/watch",
          "/v1/ack/preferences/watch",
        ])
      #expect(requests[1].body == acknowledgement)
      #expect(
        requests[1].headers["X-Mori-Transfer-ID"]
          == transferID.uuidString.lowercased()
      )
      #expect(
        requests[1].headers["X-Mori-Transfer-SHA256"]
          == digest(transfer)
      )
    }

    @Test("Experience preferences and consent transports stay on fixed channels")
    func fixedChannelTransports() async throws {
      let fixture = try RelayControlFixture()
      defer { fixture.remove() }
      let replies = ["experience-ack", "preferences-ack", "consent-ack"].map {
        Data($0.utf8)
      }
      let requester = RecordingRelayRequester(
        responses: replies.map {
          DebugLocalhostExperienceRelayHTTPResponse(
            statusCode: 200,
            headers: ["X-Mori-Acknowledgement-SHA256": digest($0)],
            body: $0
          )
        }
      )
      let client = DebugLocalhostExperienceRelayClient(
        configuration: try fixture.configuration(role: .iPhone),
        requester: requester
      )
      let experience = DebugLocalhostExperienceRelayTransport(client: client)
      let authority = DebugLocalhostGlobalAuthorityRelayTransport(client: client)

      #expect(
        try await experience.exchange(Data("experience".utf8)) == replies[0]
      )
      #expect(
        try await authority.exchange(
          channel: .preferences,
          payload: Data("preferences".utf8)
        ) == replies[1]
      )
      #expect(
        try await authority.exchange(
          channel: .consent,
          payload: Data("consent".utf8)
        ) == replies[2]
      )
      #expect(
        await requester.recordedRequests().map(\.path) == [
          "/v1/submit/experience/iphone",
          "/v1/submit/preferences/iphone",
          "/v1/submit/consent/iphone",
        ])
    }

    @Test("Server timeout conflict and queue outcomes contain no response body")
    func statusMapping() async throws {
      let fixture = try RelayControlFixture()
      defer { fixture.remove() }
      let cases:
        [(
          Int,
          DebugLocalhostExperienceRelayError
        )] = [
          (409, .transferConflict),
          (429, .queueFull),
          (504, .timedOut),
        ]
      for (status, expectedError) in cases {
        let requester = RecordingRelayRequester(responses: [
          DebugLocalhostExperienceRelayHTTPResponse(statusCode: status)
        ])
        let client = DebugLocalhostExperienceRelayClient(
          configuration: try fixture.configuration(role: .iPhone),
          requester: requester
        )
        await #expect(throws: expectedError) {
          try await client.submit(
            channel: .experience,
            body: Data("opaque".utf8)
          )
        }
      }
    }
  }

  private actor RecordingRelayRequester:
    DebugLocalhostExperienceRelayHTTPRequesting
  {
    private var responses: [DebugLocalhostExperienceRelayHTTPResponse]
    private var requests: [DebugLocalhostExperienceRelayHTTPRequest] = []

    init(responses: [DebugLocalhostExperienceRelayHTTPResponse]) {
      self.responses = responses
    }

    func send(
      baseURL: URL,
      request: DebugLocalhostExperienceRelayHTTPRequest
    ) async throws -> DebugLocalhostExperienceRelayHTTPResponse {
      #expect(baseURL.host == "127.0.0.1")
      requests.append(request)
      guard responses.isEmpty == false else {
        throw DebugLocalhostExperienceRelayError.timedOut
      }
      return responses.removeFirst()
    }

    func recordedRequests() -> [DebugLocalhostExperienceRelayHTTPRequest] {
      requests
    }
  }

  private final class RedirectingRelayURLProtocolStub:
    URLProtocol, @unchecked Sendable
  {
    nonisolated(unsafe) private static var urls: [URL] = []
    private static let lock = NSLock()

    static func reset() {
      lock.withLock { urls = [] }
    }

    static func requestedURLs() -> [URL] {
      lock.withLock { urls }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(
      for request: URLRequest
    ) -> URLRequest {
      request
    }

    override func startLoading() {
      guard
        let requestURL = request.url,
        let externalURL = URL(
          string: "http://192.0.2.1/opaque-collector"
        ),
        let response = HTTPURLResponse(
          url: requestURL,
          statusCode: 307,
          httpVersion: "HTTP/1.1",
          headerFields: ["Location": externalURL.absoluteString]
        )
      else {
        client?.urlProtocol(
          self,
          didFailWithError: URLError(.badURL)
        )
        return
      }
      Self.lock.withLock { Self.urls.append(requestURL) }
      var redirectedRequest = request
      redirectedRequest.url = externalURL
      client?.urlProtocol(
        self,
        wasRedirectedTo: redirectedRequest,
        redirectResponse: response
      )
    }

    override func stopLoading() {}
  }

  private final class RelayControlFixture {
    let url: URL
    let runID = UUID(uuidString: "183b7046-cd2b-4a86-ab6c-7a7e375c3674")!
    let token = String(repeating: "ab", count: 32)

    init(overrides: [String: String] = [:]) throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
      )
      url = directory.appendingPathComponent("relay-control.json")
      var object: [String: Any] = [
        "schemaVersion": 1,
        "host": "127.0.0.1",
        "port": 49_152,
        "runID": runID.uuidString.lowercased(),
        "token": token,
        "maximumBodyBytes":
          DebugLocalhostExperienceRelayConfiguration.maximumBodyBytes,
      ]
      for (key, value) in overrides {
        if key == "maximumBodyBytes", let integer = Int(value) {
          object[key] = integer
        } else {
          object[key] = value
        }
      }
      let data = try JSONSerialization.data(withJSONObject: object)
      #expect(
        FileManager.default.createFile(
          atPath: url.path,
          contents: data,
          attributes: [.posixPermissions: 0o600]
        )
      )
    }

    func configuration(
      role: DebugLocalhostExperienceRelayEndpointRole,
      requestTimeout: TimeInterval = 20
    ) throws -> DebugLocalhostExperienceRelayConfiguration {
      try DebugLocalhostExperienceRelayConfiguration(
        controlFileURL: url,
        role: role,
        launchArguments: ["App", "-UITesting"],
        requestTimeout: requestTimeout
      )
    }

    func remove() {
      try? FileManager.default.removeItem(
        at: url.deletingLastPathComponent()
      )
    }
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
#endif
