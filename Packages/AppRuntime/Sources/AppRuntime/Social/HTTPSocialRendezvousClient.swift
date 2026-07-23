import Foundation

public final class HTTPSocialRendezvousClient: SocialRendezvousClient, @unchecked Sendable {
  private static let createSessionTransportRetryLimit = 1

  private let baseURL: URL
  private let session: URLSession
  private let maximumSessionDuration: TimeInterval
  private let clockSkewTolerance: TimeInterval
  private let now: @Sendable () -> Date

  public init(
    baseURL: URL,
    session: URLSession = .shared,
    maximumSessionDuration: TimeInterval = 600,
    clockSkewTolerance: TimeInterval = 5,
    now: @escaping @Sendable () -> Date = Date.init
  ) throws {
    guard baseURL.scheme?.lowercased() == "https" else {
      throw SocialRendezvousError.insecureBaseURL
    }
    self.baseURL = baseURL
    self.session = session
    self.maximumSessionDuration = maximumSessionDuration
    self.clockSkewTolerance = clockSkewTolerance
    self.now = now
  }

  public func createSession(
    _ request: CreateRendezvousSessionRequest
  ) async throws -> RendezvousSessionSnapshot {
    try SocialRendezvousValidation.validate(request)
    // Encode once so a retry is byte-for-byte the same idempotent join request.
    // Rebuilding a Nearby session is a separate logical attempt and must supply
    // a newly rotated join request ID at the coordinator/UI boundary.
    let urlRequest = try makePostRequest(
      pathComponents: ["v1", "sessions"],
      body: request
    )
    var transportRetryCount = 0
    while true {
      do {
        let snapshot: RendezvousSessionSnapshot = try await send(urlRequest)
        try validateLifetime(snapshot)
        return snapshot
      } catch {
        guard transportRetryCount < Self.createSessionTransportRetryLimit,
          isRetryableTransportError(error)
        else {
          throw error
        }
        transportRetryCount += 1
      }
    }
  }

  public func status(
    _ credentials: RendezvousCredentials
  ) async throws -> RendezvousSessionSnapshot {
    try await authenticatedSessionRequest(credentials, action: "status")
  }

  public func markProximityReady(
    _ credentials: RendezvousCredentials
  ) async throws -> RendezvousSessionSnapshot {
    try await candidateSessionRequest(credentials, action: "proximity-ready")
  }

  public func fetchPeerCard(
    _ credentials: RendezvousCredentials
  ) async throws -> PeerCardSnapshot {
    try await post(
      pathComponents: ["v1", "sessions", credentials.sessionID, "peer-card"],
      body: try RendezvousCandidateRequest(credentials: credentials)
    )
  }

  public func confirm(
    _ credentials: RendezvousCredentials
  ) async throws -> RendezvousSessionSnapshot {
    try await candidateSessionRequest(credentials, action: "confirm")
  }

  public func cancel(
    _ credentials: RendezvousCredentials
  ) async throws -> RendezvousSessionSnapshot {
    try await post(
      pathComponents: ["v1", "sessions", credentials.sessionID, "cancel"],
      body: try RendezvousCancelRequest(credentials: credentials)
    )
  }

  private func authenticatedSessionRequest(
    _ credentials: RendezvousCredentials,
    action: String
  ) async throws -> RendezvousSessionSnapshot {
    let snapshot: RendezvousSessionSnapshot = try await post(
      pathComponents: ["v1", "sessions", credentials.sessionID, action],
      body: RendezvousAuthenticatedRequest(credentials: credentials)
    )
    try validateLifetime(snapshot)
    return snapshot
  }

  private func candidateSessionRequest(
    _ credentials: RendezvousCredentials,
    action: String
  ) async throws -> RendezvousSessionSnapshot {
    let snapshot: RendezvousSessionSnapshot = try await post(
      pathComponents: ["v1", "sessions", credentials.sessionID, action],
      body: try RendezvousCandidateRequest(credentials: credentials)
    )
    try validateLifetime(snapshot)
    return snapshot
  }

  private func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
    pathComponents: [String],
    body: Body
  ) async throws -> Response {
    try await send(
      makePostRequest(pathComponents: pathComponents, body: body)
    )
  }

  private func makePostRequest<Body: Encodable & Sendable>(
    pathComponents: [String],
    body: Body
  ) throws -> URLRequest {
    let endpoint = pathComponents.reduce(baseURL) {
      $0.appendingPathComponent($1, isDirectory: false)
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    request.httpBody = try encoder.encode(body)
    return request
  }

  private func send<Response: Decodable & Sendable>(
    _ request: URLRequest
  ) async throws -> Response {
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw SocialRendezvousError.invalidHTTPResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw SocialRendezvousError.server(statusCode: httpResponse.statusCode)
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Response.self, from: data)
  }

  private func isRetryableTransportError(_ error: any Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    return urlError.code != .cancelled
  }

  private func validateLifetime(_ snapshot: RendezvousSessionSnapshot) throws {
    let remaining = snapshot.expiresAt.timeIntervalSince(now())
    guard remaining >= -clockSkewTolerance else {
      throw SocialRendezvousError.expiredSession
    }
    guard remaining <= maximumSessionDuration + clockSkewTolerance else {
      throw SocialRendezvousError.sessionLifetimeExceeded
    }
  }
}
