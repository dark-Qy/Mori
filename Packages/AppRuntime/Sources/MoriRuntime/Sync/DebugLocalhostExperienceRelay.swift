#if DEBUG
  import CryptoKit
  import Foundation

  public enum DebugLocalhostExperienceRelayChannel:
    String, CaseIterable, Hashable, Sendable
  {
    case experience
    case preferences
    case consent
  }

  public enum DebugLocalhostExperienceRelayEndpointRole:
    String, CaseIterable, Hashable, Sendable
  {
    case iPhone = "iphone"
    case watch

    fileprivate var peer: Self {
      switch self {
      case .iPhone: .watch
      case .watch: .iPhone
      }
    }
  }

  public enum DebugLocalhostExperienceRelayError:
    Error, Equatable, Sendable
  {
    case uiTestingRequired
    case invalidLaunchConfiguration
    case invalidControlFile
    case insecureControlFilePermissions
    case invalidLoopbackURL
    case invalidRunID
    case invalidToken
    case oversized(actualBytes: Int, maximumBytes: Int)
    case malformedResponse
    case authenticationFailed
    case transferNotFound
    case transferConflict
    case queueFull
    case timedOut
    case serverRejected(statusCode: Int)
  }

  public struct DebugLocalhostExperienceRelayConfiguration:
    Equatable, Sendable
  {
    public static let maximumBodyBytes = 512 * 1_024

    public let baseURL: URL
    public let runID: UUID
    public let role: DebugLocalhostExperienceRelayEndpointRole
    public let requestTimeout: TimeInterval
    fileprivate let token: String

    private static let uiTestingArgument = "-UITesting"
    private static let controlFileArgumentPrefix =
      "--mori-experience-relay-control-file="
    private static let roleArgumentPrefix =
      "--mori-experience-relay-role="

    public static func loadFromLaunchArguments(
      _ launchArguments: [String] = ProcessInfo.processInfo.arguments,
      requestTimeout: TimeInterval = 20
    ) throws -> Self {
      guard launchArguments.contains(uiTestingArgument) else {
        throw DebugLocalhostExperienceRelayError.uiTestingRequired
      }
      let controlPaths = launchArguments.compactMap {
        value(after: controlFileArgumentPrefix, in: $0)
      }
      let roles = launchArguments.compactMap {
        value(after: roleArgumentPrefix, in: $0)
      }
      guard
        controlPaths.count == 1,
        roles.count == 1,
        controlPaths[0].hasPrefix("/"),
        let role = DebugLocalhostExperienceRelayEndpointRole(
          rawValue: roles[0]
        )
      else {
        throw DebugLocalhostExperienceRelayError.invalidLaunchConfiguration
      }
      return try Self(
        controlFileURL: URL(fileURLWithPath: controlPaths[0]),
        role: role,
        launchArguments: launchArguments,
        requestTimeout: requestTimeout
      )
    }

    public init(
      controlFileURL: URL,
      role: DebugLocalhostExperienceRelayEndpointRole,
      launchArguments: [String] = ProcessInfo.processInfo.arguments,
      requestTimeout: TimeInterval = 20
    ) throws {
      guard launchArguments.contains(Self.uiTestingArgument) else {
        throw DebugLocalhostExperienceRelayError.uiTestingRequired
      }
      guard
        requestTimeout.isFinite,
        requestTimeout > 0,
        requestTimeout <= 120
      else {
        throw DebugLocalhostExperienceRelayError.invalidLaunchConfiguration
      }

      let data: Data
      do {
        let attributes = try FileManager.default.attributesOfItem(
          atPath: controlFileURL.path
        )
        guard
          attributes[.type] as? FileAttributeType == .typeRegular,
          let permissions = attributes[.posixPermissions] as? NSNumber
        else {
          throw DebugLocalhostExperienceRelayError.invalidControlFile
        }
        guard permissions.intValue & 0o077 == 0 else {
          throw DebugLocalhostExperienceRelayError
            .insecureControlFilePermissions
        }
        data = try Data(contentsOf: controlFileURL)
      } catch let error as DebugLocalhostExperienceRelayError {
        throw error
      } catch {
        throw DebugLocalhostExperienceRelayError.invalidControlFile
      }
      guard data.isEmpty == false, data.count <= 4_096 else {
        throw DebugLocalhostExperienceRelayError.invalidControlFile
      }

      let control = try Self.decodeControlFile(data)
      guard
        control.schemaVersion == 1,
        control.host == "127.0.0.1",
        (1...65_535).contains(control.port),
        control.maximumBodyBytes == Self.maximumBodyBytes
      else {
        throw DebugLocalhostExperienceRelayError.invalidControlFile
      }
      guard
        let runID = UUID(uuidString: control.runID),
        runID.uuidString.lowercased() == control.runID
      else {
        throw DebugLocalhostExperienceRelayError.invalidRunID
      }
      guard Self.isValidToken(control.token) else {
        throw DebugLocalhostExperienceRelayError.invalidToken
      }
      guard
        let baseURL = URL(
          string: "http://127.0.0.1:\(control.port)"
        ),
        Self.isStrictLoopbackURL(baseURL)
      else {
        throw DebugLocalhostExperienceRelayError.invalidLoopbackURL
      }

      self.baseURL = baseURL
      self.runID = runID
      token = control.token
      self.role = role
      self.requestTimeout = requestTimeout
    }

    private static func decodeControlFile(
      _ data: Data
    ) throws -> ControlFile {
      let object: Any
      do {
        object = try JSONSerialization.jsonObject(with: data)
      } catch {
        throw DebugLocalhostExperienceRelayError.invalidControlFile
      }
      guard let dictionary = object as? [String: Any] else {
        throw DebugLocalhostExperienceRelayError.invalidControlFile
      }
      let expectedKeys: Set<String> = [
        "schemaVersion",
        "host",
        "port",
        "runID",
        "token",
        "maximumBodyBytes",
      ]
      guard Set(dictionary.keys) == expectedKeys else {
        throw DebugLocalhostExperienceRelayError.invalidControlFile
      }
      do {
        return try JSONDecoder().decode(ControlFile.self, from: data)
      } catch {
        throw DebugLocalhostExperienceRelayError.invalidControlFile
      }
    }

    private static func value(
      after prefix: String,
      in argument: String
    ) -> String? {
      guard argument.hasPrefix(prefix) else { return nil }
      return String(argument.dropFirst(prefix.count))
    }

    private static func isValidToken(_ token: String) -> Bool {
      token.utf8.count == 64
        && token.utf8.allSatisfy { byte in
          (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    fileprivate static func isStrictLoopbackURL(_ url: URL) -> Bool {
      guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      else {
        return false
      }
      return components.scheme == "http"
        && components.host == "127.0.0.1"
        && components.port.map { (1...65_535).contains($0) } == true
        && (components.path.isEmpty || components.path == "/")
        && components.user == nil
        && components.password == nil
        && components.query == nil
        && components.fragment == nil
    }

    private struct ControlFile: Decodable {
      let schemaVersion: UInt16
      let host: String
      let port: Int
      let runID: String
      let token: String
      let maximumBodyBytes: Int
    }
  }

  public enum DebugLocalhostExperienceRelayHTTPMethod:
    String, Sendable
  {
    case get = "GET"
    case post = "POST"
  }

  public struct DebugLocalhostExperienceRelayHTTPRequest: Sendable {
    public let method: DebugLocalhostExperienceRelayHTTPMethod
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public let timeout: TimeInterval

    fileprivate init(
      method: DebugLocalhostExperienceRelayHTTPMethod,
      path: String,
      headers: [String: String],
      body: Data,
      timeout: TimeInterval
    ) {
      self.method = method
      self.path = path
      self.headers = headers
      self.body = body
      self.timeout = timeout
    }
  }

  public struct DebugLocalhostExperienceRelayHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
      statusCode: Int,
      headers: [String: String] = [:],
      body: Data = Data()
    ) {
      self.statusCode = statusCode
      self.headers = headers.reduce(into: [:]) { result, field in
        result[field.key.lowercased()] = field.value
      }
      self.body = body
    }

    fileprivate func header(_ name: String) -> String? {
      headers[name.lowercased()]
    }
  }

  public protocol DebugLocalhostExperienceRelayHTTPRequesting: Sendable {
    func send(
      baseURL: URL,
      request: DebugLocalhostExperienceRelayHTTPRequest
    ) async throws -> DebugLocalhostExperienceRelayHTTPResponse
  }

  private final class DebugLocalhostExperienceRelayRedirectDelegate:
    NSObject, URLSessionTaskDelegate, @unchecked Sendable
  {
    func urlSession(
      _: URLSession,
      task _: URLSessionTask,
      willPerformHTTPRedirection _: HTTPURLResponse,
      newRequest _: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }

  public struct URLSessionDebugLocalhostExperienceRelayHTTPRequester:
    DebugLocalhostExperienceRelayHTTPRequesting, Sendable
  {
    private let session: URLSession

    public init(
      configuration: URLSessionConfiguration = .ephemeral
    ) {
      session = URLSession(
        configuration: configuration,
        delegate: DebugLocalhostExperienceRelayRedirectDelegate(),
        delegateQueue: nil
      )
    }

    public func send(
      baseURL: URL,
      request: DebugLocalhostExperienceRelayHTTPRequest
    ) async throws -> DebugLocalhostExperienceRelayHTTPResponse {
      guard
        DebugLocalhostExperienceRelayConfiguration
          .isStrictLoopbackURL(baseURL),
        request.path.hasPrefix("/v1/")
      else {
        throw DebugLocalhostExperienceRelayError.invalidLoopbackURL
      }
      var components = URLComponents(
        url: baseURL,
        resolvingAgainstBaseURL: false
      )
      components?.path = request.path
      guard
        let url = components?.url,
        DebugLocalhostExperienceRelayConfiguration
          .isStrictRelayRequestURL(url)
      else {
        throw DebugLocalhostExperienceRelayError.invalidLoopbackURL
      }
      var urlRequest = URLRequest(url: url)
      urlRequest.httpMethod = request.method.rawValue
      urlRequest.httpBody = request.body
      urlRequest.timeoutInterval = request.timeout
      for (name, value) in request.headers {
        urlRequest.setValue(value, forHTTPHeaderField: name)
      }
      let (data, response) = try await session.data(for: urlRequest)
      guard
        let httpResponse = response as? HTTPURLResponse,
        let responseURL = httpResponse.url,
        responseURL == url,
        DebugLocalhostExperienceRelayConfiguration
          .isStrictRelayRequestURL(responseURL)
      else {
        throw DebugLocalhostExperienceRelayError.malformedResponse
      }
      let headers = httpResponse.allHeaderFields.reduce(
        into: [String: String]()
      ) { result, field in
        guard
          let name = field.key as? String,
          let value = field.value as? String
        else {
          return
        }
        result[name] = value
      }
      return DebugLocalhostExperienceRelayHTTPResponse(
        statusCode: httpResponse.statusCode,
        headers: headers,
        body: data
      )
    }
  }

  extension DebugLocalhostExperienceRelayConfiguration {
    fileprivate static func isStrictRelayRequestURL(_ url: URL) -> Bool {
      guard
        let components = URLComponents(
          url: url,
          resolvingAgainstBaseURL: false
        )
      else {
        return false
      }
      let pathComponents = components.path.split(
        separator: "/",
        omittingEmptySubsequences: true
      )
      return components.scheme == "http"
        && components.host == "127.0.0.1"
        && components.port.map { (1...65_535).contains($0) } == true
        && pathComponents.count == 4
        && pathComponents[0] == "v1"
        && ["submit", "poll", "ack"].contains(pathComponents[1])
        && DebugLocalhostExperienceRelayChannel(
          rawValue: String(pathComponents[2])
        ) != nil
        && DebugLocalhostExperienceRelayEndpointRole(
          rawValue: String(pathComponents[3])
        ) != nil
        && components.user == nil
        && components.password == nil
        && components.query == nil
        && components.fragment == nil
    }
  }

  public struct DebugLocalhostExperienceRelayReceivedTransfer:
    Equatable, Sendable
  {
    public let channel: DebugLocalhostExperienceRelayChannel
    public let transferID: UUID
    public let digest: String
    public let body: Data

    fileprivate init(
      channel: DebugLocalhostExperienceRelayChannel,
      transferID: UUID,
      digest: String,
      body: Data
    ) {
      self.channel = channel
      self.transferID = transferID
      self.digest = digest
      self.body = body
    }
  }

  public actor DebugLocalhostExperienceRelayClient {
    private let configuration: DebugLocalhostExperienceRelayConfiguration
    private let requester: any DebugLocalhostExperienceRelayHTTPRequesting

    public init(
      configuration: DebugLocalhostExperienceRelayConfiguration,
      requester: any DebugLocalhostExperienceRelayHTTPRequesting =
        URLSessionDebugLocalhostExperienceRelayHTTPRequester()
    ) {
      self.configuration = configuration
      self.requester = requester
    }

    public func submit(
      channel: DebugLocalhostExperienceRelayChannel,
      body: Data,
      transferID: UUID = UUID()
    ) async throws -> Data {
      try validateBody(body)
      let digest = Self.digest(body)
      let response = try await requester.send(
        baseURL: configuration.baseURL,
        request: request(
          method: .post,
          operation: "submit",
          channel: channel,
          body: body,
          additionalHeaders: [
            "X-Mori-Transfer-ID": transferID.uuidString.lowercased(),
            "X-Mori-Transfer-SHA256": digest,
          ]
        )
      )
      try validateCommonStatus(response)
      guard response.statusCode == 200 else {
        throw error(for: response.statusCode)
      }
      try validateBody(response.body)
      guard
        let acknowledgementDigest = response.header(
          "X-Mori-Acknowledgement-SHA256"
        ),
        acknowledgementDigest == Self.digest(response.body)
      else {
        throw DebugLocalhostExperienceRelayError.malformedResponse
      }
      return response.body
    }

    public func poll(
      channel: DebugLocalhostExperienceRelayChannel
    ) async throws -> DebugLocalhostExperienceRelayReceivedTransfer? {
      let response = try await requester.send(
        baseURL: configuration.baseURL,
        request: request(
          method: .get,
          operation: "poll",
          channel: channel,
          body: Data()
        )
      )
      try validateCommonStatus(response)
      if response.statusCode == 204 {
        guard response.body.isEmpty else {
          throw DebugLocalhostExperienceRelayError.malformedResponse
        }
        return nil
      }
      guard response.statusCode == 200 else {
        throw error(for: response.statusCode)
      }
      try validateBody(response.body)
      guard
        let rawTransferID = response.header("X-Mori-Transfer-ID"),
        let transferID = UUID(uuidString: rawTransferID),
        transferID.uuidString.lowercased() == rawTransferID.lowercased(),
        let digest = response.header("X-Mori-Transfer-SHA256"),
        digest == Self.digest(response.body),
        response.header("X-Mori-Sender-Role")
          == configuration.role.peer.rawValue
      else {
        throw DebugLocalhostExperienceRelayError.malformedResponse
      }
      return DebugLocalhostExperienceRelayReceivedTransfer(
        channel: channel,
        transferID: transferID,
        digest: digest,
        body: response.body
      )
    }

    public func acknowledge(
      _ transfer: DebugLocalhostExperienceRelayReceivedTransfer,
      body: Data
    ) async throws {
      try validateBody(body)
      let response = try await requester.send(
        baseURL: configuration.baseURL,
        request: request(
          method: .post,
          operation: "ack",
          channel: transfer.channel,
          body: body,
          additionalHeaders: [
            "X-Mori-Transfer-ID":
              transfer.transferID.uuidString.lowercased(),
            "X-Mori-Transfer-SHA256": transfer.digest,
          ]
        )
      )
      try validateCommonStatus(response)
      guard response.statusCode == 204, response.body.isEmpty else {
        if response.statusCode != 204 {
          throw error(for: response.statusCode)
        }
        throw DebugLocalhostExperienceRelayError.malformedResponse
      }
    }

    private func request(
      method: DebugLocalhostExperienceRelayHTTPMethod,
      operation: String,
      channel: DebugLocalhostExperienceRelayChannel,
      body: Data,
      additionalHeaders: [String: String] = [:]
    ) -> DebugLocalhostExperienceRelayHTTPRequest {
      var headers = [
        "Authorization": "Bearer \(configuration.token)",
        "X-Mori-Relay-Run-ID":
          configuration.runID.uuidString.lowercased(),
      ]
      if method == .post {
        headers["Content-Type"] = "application/octet-stream"
      }
      headers.merge(additionalHeaders) { _, new in new }
      return DebugLocalhostExperienceRelayHTTPRequest(
        method: method,
        path:
          "/v1/\(operation)/\(channel.rawValue)/"
          + configuration.role.rawValue,
        headers: headers,
        body: body,
        timeout: configuration.requestTimeout
      )
    }

    private func validateBody(_ body: Data) throws {
      guard
        body.count
          <= DebugLocalhostExperienceRelayConfiguration.maximumBodyBytes
      else {
        throw DebugLocalhostExperienceRelayError.oversized(
          actualBytes: body.count,
          maximumBytes:
            DebugLocalhostExperienceRelayConfiguration.maximumBodyBytes
        )
      }
    }

    private func validateCommonStatus(
      _ response: DebugLocalhostExperienceRelayHTTPResponse
    ) throws {
      guard
        response.body.count
          <= DebugLocalhostExperienceRelayConfiguration.maximumBodyBytes
      else {
        throw DebugLocalhostExperienceRelayError.oversized(
          actualBytes: response.body.count,
          maximumBytes:
            DebugLocalhostExperienceRelayConfiguration.maximumBodyBytes
        )
      }
      if response.statusCode != 200, response.statusCode != 204,
        response.body.isEmpty == false
      {
        throw DebugLocalhostExperienceRelayError.malformedResponse
      }
      if response.statusCode == 401 {
        throw DebugLocalhostExperienceRelayError.authenticationFailed
      }
    }

    private func error(
      for statusCode: Int
    ) -> DebugLocalhostExperienceRelayError {
      switch statusCode {
      case 401: .authenticationFailed
      case 404: .transferNotFound
      case 409: .transferConflict
      case 429: .queueFull
      case 504: .timedOut
      default: .serverRejected(statusCode: statusCode)
      }
    }

    private static func digest(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
  }

  public struct DebugLocalhostExperienceRelayTransport:
    ExperienceSyncTransport, Sendable
  {
    private let client: DebugLocalhostExperienceRelayClient

    public init(client: DebugLocalhostExperienceRelayClient) {
      self.client = client
    }

    public func exchange(_ transferData: Data) async throws -> Data {
      try await client.submit(channel: .experience, body: transferData)
    }
  }

  public struct DebugLocalhostGlobalAuthorityRelayTransport:
    GlobalAuthorityPeerTransport, Sendable
  {
    private let client: DebugLocalhostExperienceRelayClient

    public init(client: DebugLocalhostExperienceRelayClient) {
      self.client = client
    }

    public func exchange(
      channel: GlobalAuthoritySyncChannel,
      payload: Data
    ) async throws -> Data {
      let relayChannel: DebugLocalhostExperienceRelayChannel =
        switch channel {
        case .preferences: .preferences
        case .consent: .consent
        }
      return try await client.submit(
        channel: relayChannel,
        body: payload
      )
    }
  }

  public actor DebugLocalhostExperienceRelayPeerPump {
    public typealias Handler =
      @Sendable (Data) async throws -> Data

    private let client: DebugLocalhostExperienceRelayClient
    private let retryDelay: Duration
    private var tasks: [DebugLocalhostExperienceRelayChannel: Task<Void, Never>] = [:]

    public init(
      client: DebugLocalhostExperienceRelayClient,
      retryDelay: Duration = .milliseconds(100)
    ) {
      self.client = client
      self.retryDelay =
        retryDelay > .zero ? retryDelay : .milliseconds(1)
    }

    public func start(
      channel: DebugLocalhostExperienceRelayChannel,
      handler: @escaping Handler
    ) {
      guard tasks[channel] == nil else { return }
      let client = self.client
      let retryDelay = self.retryDelay
      tasks[channel] = Task {
        while Task.isCancelled == false {
          do {
            guard
              let transfer = try await client.poll(channel: channel)
            else {
              continue
            }
            let acknowledgement = try await handler(transfer.body)
            try await client.acknowledge(
              transfer,
              body: acknowledgement
            )
          } catch is CancellationError {
            return
          } catch {
            do {
              try await Task.sleep(for: retryDelay)
            } catch {
              return
            }
          }
        }
      }
    }

    public func stop(
      channel: DebugLocalhostExperienceRelayChannel
    ) {
      tasks.removeValue(forKey: channel)?.cancel()
    }

    public func stopAll() {
      let running = tasks.values
      tasks.removeAll()
      for task in running {
        task.cancel()
      }
    }

    @discardableResult
    public func pumpOnce(
      channel: DebugLocalhostExperienceRelayChannel,
      handler: Handler
    ) async throws -> Bool {
      guard let transfer = try await client.poll(channel: channel) else {
        return false
      }
      let acknowledgement = try await handler(transfer.body)
      try await client.acknowledge(
        transfer,
        body: acknowledgement
      )
      return true
    }
  }
#endif
