import Foundation
import MoriDomain
import MoriPersistence

public protocol PendingGlancePresentationFenceStorage: Sendable {
  func load() async throws -> Data?
  func save(_ data: Data) async throws
}

public actor InMemoryPendingGlancePresentationFenceStorage:
  PendingGlancePresentationFenceStorage
{
  private var data: Data?

  public init(data: Data? = nil) {
    self.data = data
  }

  public func load() -> Data? {
    data
  }

  public func save(_ data: Data) {
    self.data = data
  }
}

public actor FilePendingGlancePresentationFenceStorage:
  PendingGlancePresentationFenceStorage
{
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }
    return try Data(contentsOf: fileURL)
  }

  public func save(_ data: Data) throws {
    try ProtectedAtomicFile.write(data, to: fileURL)
  }
}

struct PendingGlancePresentationFenceScope:
  Hashable, Codable, Sendable
{
  let profileID: ProfileID
  let profileEpoch: ProfileEpoch
  let deletionEpoch: DeletionEpoch
  let terminalEventIDs: [EventID]

  init(
    profile: RuntimeProfile,
    terminalEventIDs: [EventID]
  ) {
    profileID = profile.id
    profileEpoch = profile.epoch
    deletionEpoch = profile.deletionEpoch
    self.terminalEventIDs = terminalEventIDs.sorted()
  }

  func matches(_ profile: RuntimeProfile) -> Bool {
    profileID == profile.id
      && profileEpoch == profile.epoch
      && deletionEpoch == profile.deletionEpoch
  }

  var isValid: Bool {
    profileID.isValid
      && profileEpoch.isValid
      && deletionEpoch.isValid
      && terminalEventIDs.allSatisfy(\.isValid)
      && terminalEventIDs == terminalEventIDs.sorted()
      && Set(terminalEventIDs).count == terminalEventIDs.count
  }
}

struct PendingGlancePresentationFenceSnapshot:
  Hashable, Codable, Sendable
{
  static let currentSchemaVersion: UInt16 = 1
  static let maximumScopeCount = 64
  static let maximumEventCount = 16_384

  let schemaVersion: UInt16
  let scopes: [PendingGlancePresentationFenceScope]

  init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    scopes: [PendingGlancePresentationFenceScope] = []
  ) {
    self.schemaVersion = schemaVersion
    self.scopes = scopes.sorted(by: Self.scopeIsOlder)
  }

  var isValid: Bool {
    schemaVersion == Self.currentSchemaVersion
      && scopes.count <= Self.maximumScopeCount
      && scopes.reduce(0) { $0 + $1.terminalEventIDs.count }
        <= Self.maximumEventCount
      && scopes.allSatisfy(\.isValid)
      && scopes == scopes.sorted(by: Self.scopeIsOlder)
      && Set(scopes.map(ScopeIdentity.init)).count == scopes.count
  }

  func terminalEventIDs(
    for profile: RuntimeProfile
  ) -> Set<EventID> {
    Set(
      scopes.first(where: { $0.matches(profile) })?
        .terminalEventIDs ?? []
    )
  }

  func appending(
    eventIDs: [EventID],
    for profile: RuntimeProfile
  ) -> Self {
    let additions = Set(eventIDs)
    var updatedScopes = scopes
    if let index = updatedScopes.firstIndex(
      where: { $0.matches(profile) }
    ) {
      updatedScopes[index] = PendingGlancePresentationFenceScope(
        profile: profile,
        terminalEventIDs: Array(
          Set(updatedScopes[index].terminalEventIDs).union(additions)
        )
      )
    } else {
      updatedScopes.append(
        PendingGlancePresentationFenceScope(
          profile: profile,
          terminalEventIDs: Array(additions)
        )
      )
    }
    return Self(scopes: updatedScopes)
  }

  private struct ScopeIdentity: Hashable {
    let profileID: ProfileID
    let profileEpoch: ProfileEpoch
    let deletionEpoch: DeletionEpoch

    init(_ scope: PendingGlancePresentationFenceScope) {
      profileID = scope.profileID
      profileEpoch = scope.profileEpoch
      deletionEpoch = scope.deletionEpoch
    }
  }

  private static func scopeIsOlder(
    _ lhs: PendingGlancePresentationFenceScope,
    _ rhs: PendingGlancePresentationFenceScope
  ) -> Bool {
    if lhs.profileID != rhs.profileID {
      return lhs.profileID < rhs.profileID
    }
    if lhs.profileEpoch != rhs.profileEpoch {
      return lhs.profileEpoch < rhs.profileEpoch
    }
    return lhs.deletionEpoch < rhs.deletionEpoch
  }
}

enum PendingGlancePresentationFenceError:
  Error, Equatable, Sendable
{
  case oversized(actualBytes: Int, maximumBytes: Int)
  case malformed
  case nonCanonical
  case invalidSnapshot
  case invalidProfile
}

struct PendingGlancePresentationFenceCodec: Sendable {
  static let defaultMaximumBytes = 1_024 * 1_024

  private let maximumBytes: Int
  private let codec: CanonicalJSONCodec

  init(
    maximumBytes: Int = Self.defaultMaximumBytes,
    codec: CanonicalJSONCodec = CanonicalJSONCodec()
  ) {
    self.maximumBytes = max(1, maximumBytes)
    self.codec = codec
  }

  func encode(
    _ snapshot: PendingGlancePresentationFenceSnapshot
  ) throws -> Data {
    guard snapshot.isValid else {
      throw PendingGlancePresentationFenceError.invalidSnapshot
    }
    let data = try codec.encode(snapshot)
    try validateSize(data)
    return data
  }

  func decode(
    _ data: Data
  ) throws -> PendingGlancePresentationFenceSnapshot {
    try validateSize(data)
    let snapshot: PendingGlancePresentationFenceSnapshot
    do {
      snapshot = try codec.decode(
        PendingGlancePresentationFenceSnapshot.self,
        from: data
      )
    } catch {
      throw PendingGlancePresentationFenceError.malformed
    }
    guard snapshot.isValid else {
      throw PendingGlancePresentationFenceError.invalidSnapshot
    }
    let canonical = try codec.encode(snapshot)
    guard data == canonical else {
      // Exact comparison rejects undeclared fields and alternate encodings.
      throw PendingGlancePresentationFenceError.nonCanonical
    }
    return snapshot
  }

  private func validateSize(_ data: Data) throws {
    guard data.count <= maximumBytes else {
      throw PendingGlancePresentationFenceError.oversized(
        actualBytes: data.count,
        maximumBytes: maximumBytes
      )
    }
  }
}
