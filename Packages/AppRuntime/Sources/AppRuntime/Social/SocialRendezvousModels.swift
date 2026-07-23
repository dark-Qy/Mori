import AppleAdapters
import Foundation

public struct CreateRendezvousSessionRequest: Codable, Equatable, Sendable {
  public let participantID: String
  public let discoveryToken: Data
  public let publicCard: PublicPetCardV1
  public let joinRequestID: String

  public init(
    participantID: String,
    discoveryToken: NearbyDiscoveryToken,
    publicCard: PublicPetCardV1,
    joinRequestID: String
  ) {
    self.participantID = participantID
    self.discoveryToken = discoveryToken.encodedValue
    self.publicCard = publicCard
    self.joinRequestID = joinRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case participantID = "participant_id"
    case discoveryToken = "discovery_token"
    case publicCard = "public_card"
    case joinRequestID = "join_request_id"
  }
}

public struct RendezvousCredentials: Codable, Equatable, Sendable {
  public let sessionID: String
  public let participantID: String
  public let nonce: String
  public let encounterID: String?
  public let encounterNonce: String?

  public init(
    sessionID: String,
    participantID: String,
    nonce: String,
    encounterID: String? = nil,
    encounterNonce: String? = nil
  ) {
    self.sessionID = sessionID
    self.participantID = participantID
    self.nonce = nonce
    self.encounterID = encounterID
    self.encounterNonce = encounterNonce
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case participantID = "participant_id"
    case nonce
    case encounterID = "encounter_id"
    case encounterNonce = "encounter_nonce"
  }

  public var encounterIdentity: RendezvousEncounterIdentity? {
    guard let encounterID, let encounterNonce else { return nil }
    return RendezvousEncounterIdentity(id: encounterID, nonce: encounterNonce)
  }

  public func replacingEncounter(
    with identity: RendezvousEncounterIdentity?
  ) -> RendezvousCredentials {
    RendezvousCredentials(
      sessionID: sessionID,
      participantID: participantID,
      nonce: nonce,
      encounterID: identity?.id,
      encounterNonce: identity?.nonce
    )
  }
}

public struct RendezvousAuthenticatedRequest: Codable, Equatable, Sendable {
  public let participantID: String
  public let nonce: String

  public init(credentials: RendezvousCredentials) {
    participantID = credentials.participantID
    nonce = credentials.nonce
  }

  private enum CodingKeys: String, CodingKey {
    case participantID = "participant_id"
    case nonce
  }
}

public struct RendezvousCancelRequest: Codable, Equatable, Sendable {
  public let participantID: String
  public let nonce: String
  public let encounterID: String?
  public let encounterNonce: String?

  public init(credentials: RendezvousCredentials) throws {
    try credentials.validateEncounterPair()
    participantID = credentials.participantID
    nonce = credentials.nonce
    encounterID = credentials.encounterID
    encounterNonce = credentials.encounterNonce
  }

  private enum CodingKeys: String, CodingKey {
    case participantID = "participant_id"
    case nonce
    case encounterID = "encounter_id"
    case encounterNonce = "encounter_nonce"
  }
}

public struct RendezvousCandidateRequest: Codable, Equatable, Sendable {
  public let participantID: String
  public let nonce: String
  public let encounterID: String
  public let encounterNonce: String

  public init(credentials: RendezvousCredentials) throws {
    try credentials.validateEncounterPair()
    guard let identity = credentials.encounterIdentity else {
      throw SocialRendezvousError.missingCredentials
    }
    participantID = credentials.participantID
    nonce = credentials.nonce
    encounterID = identity.id
    encounterNonce = identity.nonce
  }

  private enum CodingKeys: String, CodingKey {
    case participantID = "participant_id"
    case nonce
    case encounterID = "encounter_id"
    case encounterNonce = "encounter_nonce"
  }
}

public struct RendezvousEncounterIdentity: Codable, Equatable, Hashable, Sendable {
  public let id: String
  public let nonce: String

  public init(id: String, nonce: String) {
    self.id = id
    self.nonce = nonce
  }
}

/// Open-ended status value so a newer server can add a status without making
/// an older client fail to decode the complete response.
public struct RendezvousStatus: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let waitingForPeer = Self(rawValue: "waiting")
  public static let matched = Self(rawValue: "matched")
  public static let proximityReady = Self(rawValue: "proximity_ready")
  public static let awaitingConfirmations = Self(rawValue: "awaiting_confirmations")
  public static let confirmed = Self(rawValue: "confirmed")
  public static let cancelled = Self(rawValue: "cancelled")
  public static let expired = Self(rawValue: "expired")
}

public struct RendezvousSessionSnapshot: Codable, Equatable, Sendable {
  public let sessionID: String
  public let nonce: String?
  public let status: RendezvousStatus
  public let expiresAt: Date
  public let encounterID: String?
  public let encounterNonce: String?
  public let peerDiscoveryToken: Data?
  public let selfProximityReady: Bool?
  public let peerProximityReady: Bool?
  public let proximityVerified: Bool?
  public let proximityVerifiedAt: Date?
  public let selfPreviewReleased: Bool?
  public let peerPreviewReleased: Bool?
  public let selfConfirmed: Bool?
  public let peerConfirmed: Bool?

  public init(
    sessionID: String,
    nonce: String? = nil,
    status: RendezvousStatus,
    expiresAt: Date,
    encounterID: String? = nil,
    encounterNonce: String? = nil,
    peerDiscoveryToken: Data? = nil,
    selfProximityReady: Bool? = nil,
    peerProximityReady: Bool? = nil,
    proximityVerified: Bool? = nil,
    proximityVerifiedAt: Date? = nil,
    selfPreviewReleased: Bool? = nil,
    peerPreviewReleased: Bool? = nil,
    selfConfirmed: Bool? = nil,
    peerConfirmed: Bool? = nil
  ) {
    self.sessionID = sessionID
    self.nonce = nonce
    self.status = status
    self.expiresAt = expiresAt
    self.encounterID = encounterID
    self.encounterNonce = encounterNonce
    self.peerDiscoveryToken = peerDiscoveryToken
    self.selfProximityReady = selfProximityReady
    self.peerProximityReady = peerProximityReady
    self.proximityVerified = proximityVerified
    self.proximityVerifiedAt = proximityVerifiedAt
    self.selfPreviewReleased = selfPreviewReleased
    self.peerPreviewReleased = peerPreviewReleased
    self.selfConfirmed = selfConfirmed
    self.peerConfirmed = peerConfirmed
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case nonce
    case status
    case expiresAt = "expires_at"
    case encounterID = "encounter_id"
    case encounterNonce = "encounter_nonce"
    case peerDiscoveryToken = "peer_discovery_token"
    case selfProximityReady = "self_proximity_ready"
    case peerProximityReady = "peer_proximity_ready"
    case proximityVerified = "proximity_verified"
    case proximityVerifiedAt = "proximity_verified_at"
    case selfPreviewReleased = "self_preview_released"
    case peerPreviewReleased = "peer_preview_released"
    case selfConfirmed = "self_confirmed"
    case peerConfirmed = "peer_confirmed"
  }

  public var peerToken: NearbyDiscoveryToken? {
    peerDiscoveryToken.map(NearbyDiscoveryToken.init(encodedValue:))
  }

  public var encounterIdentity: RendezvousEncounterIdentity? {
    get throws {
      switch (encounterID, encounterNonce) {
      case (.none, .none):
        return nil
      case (.some(let id), .some(let nonce)):
        return RendezvousEncounterIdentity(id: id, nonce: nonce)
      case (.some, .none), (.none, .some):
        throw SocialRendezvousError.incompleteEncounterIdentity
      }
    }
  }
}

public struct PeerCardSnapshot: Codable, Equatable, Sendable {
  public let encounterID: String
  public let encounterNonce: String
  public let status: RendezvousStatus?
  public let card: PublicPetCardV1

  public init(
    encounterID: String,
    encounterNonce: String,
    status: RendezvousStatus? = nil,
    card: PublicPetCardV1
  ) {
    self.encounterID = encounterID
    self.encounterNonce = encounterNonce
    self.status = status
    self.card = card
  }

  private enum CodingKeys: String, CodingKey {
    case encounterID = "encounter_id"
    case encounterNonce = "encounter_nonce"
    case status
    case card = "public_card"
  }
}

public enum SocialRendezvousError: Error, Equatable, Sendable {
  case insecureBaseURL
  case invalidHTTPResponse
  case server(statusCode: Int)
  case expiredSession
  case sessionLifetimeExceeded
  case invalidParticipantID
  case invalidDiscoveryToken
  case invalidJoinRequestID
  case missingNonce
  case missingCredentials
  case incompleteEncounterIdentity
  case encounterIdentityMismatch
  case missingPeerToken
  case invalidMockCredentials
}

extension RendezvousCredentials {
  public func validateEncounterPair() throws {
    guard (encounterID == nil) == (encounterNonce == nil) else {
      throw SocialRendezvousError.incompleteEncounterIdentity
    }
  }
}

enum SocialRendezvousValidation {
  static func validate(_ request: CreateRendezvousSessionRequest) throws {
    guard isOpaqueIdentifier(request.participantID) else {
      throw SocialRendezvousError.invalidParticipantID
    }
    guard isOpaqueIdentifier(request.joinRequestID) else {
      throw SocialRendezvousError.invalidJoinRequestID
    }
    guard (1...2_048).contains(request.discoveryToken.count) else {
      throw SocialRendezvousError.invalidDiscoveryToken
    }
    try request.publicCard.validateForTransport()
  }

  private static func isOpaqueIdentifier(_ value: String) -> Bool {
    (16...128).contains(value.count)
      && value.allSatisfy({
        ("a"..."z").contains($0)
          || ("A"..."Z").contains($0)
          || ("0"..."9").contains($0)
          || $0 == "_"
          || $0 == "-"
      })
  }
}

public protocol SocialRendezvousClient: Sendable {
  func createSession(
    _ request: CreateRendezvousSessionRequest
  ) async throws -> RendezvousSessionSnapshot

  func status(
    _ credentials: RendezvousCredentials
  ) async throws -> RendezvousSessionSnapshot

  func markProximityReady(
    _ credentials: RendezvousCredentials
  ) async throws -> RendezvousSessionSnapshot

  func fetchPeerCard(
    _ credentials: RendezvousCredentials
  ) async throws -> PeerCardSnapshot

  func confirm(
    _ credentials: RendezvousCredentials
  ) async throws -> RendezvousSessionSnapshot

  func cancel(
    _ credentials: RendezvousCredentials
  ) async throws -> RendezvousSessionSnapshot
}
