import Foundation

/// A repeatable, in-process rendezvous used by the simulator and previews.
/// It performs no network access and exposes stable identifiers by default.
public actor DeterministicMockSocialRendezvousClient: SocialRendezvousClient {
  public struct Configuration: Equatable, Sendable {
    public let sessionID: String
    public let nonce: String
    public let encounterID: String
    public let encounterNonce: String
    public let peerDiscoveryToken: Data
    public let peerCard: PublicPetCardV1
    public let expiresAt: Date
    public let peerReadyAfterMarkCount: Int
    public let peerConfirmsBeforeLocal: Bool

    public init(
      sessionID: String = "mock-session-1",
      nonce: String = "mock-nonce-1",
      encounterID: String = "mock-encounter-1",
      encounterNonce: String = "mock-encounter-nonce-1",
      peerDiscoveryToken: Data = Data([0x02]),
      peerCard: PublicPetCardV1 = PublicPetCardV1(
        petName: "Nearby Friend",
        characterID: "pet.mock.friend",
        outfitID: "outfit.mock.default",
        backgroundID: "background.mock.default",
        socialState: .greeting
      ),
      expiresAt: Date = Date(timeIntervalSince1970: 4_102_444_800),
      peerReadyAfterMarkCount: Int = 1,
      peerConfirmsBeforeLocal: Bool = false
    ) {
      self.sessionID = sessionID
      self.nonce = nonce
      self.encounterID = encounterID
      self.encounterNonce = encounterNonce
      self.peerDiscoveryToken = peerDiscoveryToken
      self.peerCard = peerCard
      self.expiresAt = expiresAt
      self.peerReadyAfterMarkCount = max(1, peerReadyAfterMarkCount)
      self.peerConfirmsBeforeLocal = peerConfirmsBeforeLocal
    }
  }

  public private(set) var callLog: [String] = []

  private let configuration: Configuration
  private var participantID: String?
  private var currentStatus: RendezvousStatus = .waitingForPeer
  private var selfProximityReady = false
  private var peerProximityReady = false
  private var selfConfirmed = false
  private var peerConfirmed = false
  private var proximityMarkCount = 0
  private var selfPreviewReleased = false
  private var peerPreviewReleased = false

  public init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
  }

  public func createSession(
    _ request: CreateRendezvousSessionRequest
  ) throws -> RendezvousSessionSnapshot {
    try SocialRendezvousValidation.validate(request)
    callLog.append("create")
    participantID = request.participantID
    currentStatus = .waitingForPeer
    selfProximityReady = false
    peerProximityReady = false
    selfConfirmed = false
    peerConfirmed = false
    proximityMarkCount = 0
    selfPreviewReleased = false
    peerPreviewReleased = false
    return snapshot(includePeerToken: false)
  }

  public func status(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validate(credentials)
    callLog.append("status")
    if currentStatus == .waitingForPeer {
      currentStatus = .matched
    }
    if configuration.peerConfirmsBeforeLocal, selfProximityReady, peerProximityReady {
      peerPreviewReleased = true
      peerConfirmed = true
      currentStatus = .awaitingConfirmations
    }
    return snapshot(includePeerToken: true)
  }

  public func markProximityReady(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validateCandidate(credentials)
    callLog.append("proximity-ready")
    currentStatus = .proximityReady
    selfProximityReady = true
    proximityMarkCount += 1
    peerProximityReady =
      proximityMarkCount >= configuration.peerReadyAfterMarkCount
    return snapshot(includePeerToken: true)
  }

  public func fetchPeerCard(
    _ credentials: RendezvousCredentials
  ) throws -> PeerCardSnapshot {
    try validateCandidate(credentials)
    callLog.append("peer-card")
    selfPreviewReleased = true
    return PeerCardSnapshot(
      encounterID: configuration.encounterID,
      encounterNonce: configuration.encounterNonce,
      status: currentStatus,
      card: configuration.peerCard
    )
  }

  public func confirm(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validateCandidate(credentials)
    callLog.append("confirm")
    currentStatus = .confirmed
    selfConfirmed = true
    peerConfirmed = true
    return snapshot(includePeerToken: true)
  }

  public func cancel(
    _ credentials: RendezvousCredentials
  ) throws -> RendezvousSessionSnapshot {
    try validate(credentials)
    callLog.append("cancel")
    currentStatus = .cancelled
    return snapshot(includePeerToken: false)
  }

  private func validate(_ credentials: RendezvousCredentials) throws {
    guard credentials.sessionID == configuration.sessionID,
      credentials.nonce == configuration.nonce,
      credentials.participantID == participantID
    else {
      throw SocialRendezvousError.invalidMockCredentials
    }
    let expectedIdentity =
      currentStatus == .waitingForPeer
      ? nil
      : RendezvousEncounterIdentity(
        id: configuration.encounterID,
        nonce: configuration.encounterNonce
      )
    guard credentials.encounterIdentity == expectedIdentity else {
      throw SocialRendezvousError.encounterIdentityMismatch
    }
  }

  private func validateCandidate(_ credentials: RendezvousCredentials) throws {
    try validate(credentials)
    guard credentials.encounterIdentity != nil else {
      throw SocialRendezvousError.missingCredentials
    }
  }

  private func snapshot(includePeerToken: Bool) -> RendezvousSessionSnapshot {
    RendezvousSessionSnapshot(
      sessionID: configuration.sessionID,
      nonce: configuration.nonce,
      status: currentStatus,
      expiresAt: configuration.expiresAt,
      encounterID: currentStatus == .waitingForPeer ? nil : configuration.encounterID,
      encounterNonce: currentStatus == .waitingForPeer ? nil : configuration.encounterNonce,
      peerDiscoveryToken: includePeerToken ? configuration.peerDiscoveryToken : nil,
      selfProximityReady: selfProximityReady,
      peerProximityReady: peerProximityReady,
      proximityVerified: selfProximityReady && peerProximityReady,
      proximityVerifiedAt: selfProximityReady && peerProximityReady
        ? configuration.expiresAt.addingTimeInterval(-60)
        : nil,
      selfPreviewReleased: selfPreviewReleased,
      peerPreviewReleased: peerPreviewReleased,
      selfConfirmed: selfConfirmed,
      peerConfirmed: peerConfirmed
    )
  }
}
