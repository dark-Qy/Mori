import CryptoKit
import Foundation
import MoriDomain
import MoriPersistence

public struct GlobalAuthoritySnapshot: Hashable, Codable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let preferences: GlobalSyncedPreferences
  public let consent: GlobalConsentState

  public init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    preferences: GlobalSyncedPreferences,
    consent: GlobalConsentState
  ) {
    self.schemaVersion = schemaVersion
    self.preferences = preferences
    self.consent = consent
  }

  public var isValid: Bool {
    schemaVersion == Self.currentSchemaVersion
      && preferences.isValid
      && consent.isValid
      && deletionRoot.isValid
  }

  public var deletionRoot: DeletionAuthorityRoot {
    preferences.profileSelection.profile.deletionAuthorityRoot
  }
}

public enum GlobalAuthorityCodecError: Error, Equatable, Sendable {
  case oversized(actualBytes: Int, maximumBytes: Int)
  case malformed
  case undeclaredField(String)
  case nonCanonical
  case invalidSnapshot
}

public enum GlobalAuthorityRepositoryError: Error, Equatable, Sendable {
  case staleStorageRevision
  case deletionRootMismatch(
    expected: DeletionAuthorityRoot,
    received: DeletionAuthorityRoot
  )
}

public struct GlobalAuthorityCodec: Sendable {
  public static let defaultMaximumBytes = 128 * 1_024

  private let maximumBytes: Int
  private let codec: CanonicalJSONCodec

  public init(
    maximumBytes: Int = Self.defaultMaximumBytes,
    codec: CanonicalJSONCodec = CanonicalJSONCodec()
  ) {
    self.maximumBytes = max(1, maximumBytes)
    self.codec = codec
  }

  public func encode(_ snapshot: GlobalAuthoritySnapshot) throws -> Data {
    guard snapshot.isValid else {
      throw GlobalAuthorityCodecError.invalidSnapshot
    }
    let data = try codec.encode(snapshot)
    try validateSize(data)
    return data
  }

  public func decode(_ data: Data) throws -> GlobalAuthoritySnapshot {
    try validateSize(data)
    let decoded: GlobalAuthoritySnapshot
    do {
      decoded = try codec.decode(GlobalAuthoritySnapshot.self, from: data)
    } catch {
      throw GlobalAuthorityCodecError.malformed
    }
    let migrated = migrateLegacyMockBootstrap(in: decoded)
    guard decoded.isValid || migrated != nil else {
      throw GlobalAuthorityCodecError.invalidSnapshot
    }
    let decodedCanonical = try codec.encode(decoded)
    try rejectUndeclaredFields(in: data, canonical: decodedCanonical)
    guard data == decodedCanonical else {
      throw GlobalAuthorityCodecError.nonCanonical
    }
    let snapshot = migrated ?? decoded
    guard snapshot.isValid else {
      throw GlobalAuthorityCodecError.invalidSnapshot
    }
    return snapshot
  }

  private func validateSize(_ data: Data) throws {
    guard data.count <= maximumBytes else {
      throw GlobalAuthorityCodecError.oversized(
        actualBytes: data.count,
        maximumBytes: maximumBytes
      )
    }
  }

  private func rejectUndeclaredFields(in sourceData: Data, canonical canonicalData: Data) throws {
    let source: Any
    let canonical: Any
    do {
      source = try JSONSerialization.jsonObject(with: sourceData)
      canonical = try JSONSerialization.jsonObject(with: canonicalData)
    } catch {
      throw GlobalAuthorityCodecError.malformed
    }
    if let field = firstUndeclaredField(
      in: source,
      comparedTo: canonical,
      path: "$"
    ) {
      throw GlobalAuthorityCodecError.undeclaredField(field)
    }
  }

  private func migrateLegacyMockBootstrap(
    in snapshot: GlobalAuthoritySnapshot
  ) -> GlobalAuthoritySnapshot? {
    let selection = snapshot.preferences.profileSelection
    let profile = selection.profile
    guard
      selection.schemaVersion == ProfileSelectionRecord.currentSchemaVersion,
      selection.revision == profile.epoch.revision,
      let migrated = MockProfileBootstrapMigration.migrate(profile)
    else {
      return nil
    }
    let preferences = GlobalSyncedPreferences(
      profileSelection: ProfileSelectionRecord(
        profile: migrated,
        revision: selection.revision
      ),
      companionSensing: snapshot.preferences.companionSensing,
      reminderMode: snapshot.preferences.reminderMode,
      quietHours: snapshot.preferences.quietHours
    )
    return GlobalAuthoritySnapshot(
      schemaVersion: snapshot.schemaVersion,
      preferences: preferences,
      consent: snapshot.consent
    )
  }

  private func firstUndeclaredField(
    in source: Any,
    comparedTo canonical: Any,
    path: String
  ) -> String? {
    if let source = source as? [String: Any] {
      guard let canonical = canonical as? [String: Any] else { return path }
      for key in source.keys.sorted() {
        guard let canonicalValue = canonical[key] else {
          return "\(path).\(key)"
        }
        if let field = firstUndeclaredField(
          in: source[key]!,
          comparedTo: canonicalValue,
          path: "\(path).\(key)"
        ) {
          return field
        }
      }
      return nil
    }
    if let source = source as? [Any] {
      guard let canonical = canonical as? [Any], source.count == canonical.count else {
        return path
      }
      for index in source.indices {
        if let field = firstUndeclaredField(
          in: source[index],
          comparedTo: canonical[index],
          path: "\(path)[\(index)]"
        ) {
          return field
        }
      }
    }
    return nil
  }
}

public enum GlobalAuthorityStorageRevision: Hashable, Sendable {
  case absent
  case digest(String)

  static func current(for data: Data?) -> Self {
    guard let data else { return .absent }
    let digest = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    return .digest(digest)
  }
}

public struct GlobalAuthorityStorageSnapshot: Sendable {
  public let data: Data?
  public let revision: GlobalAuthorityStorageRevision

  public init(
    data: Data?,
    revision: GlobalAuthorityStorageRevision
  ) {
    self.data = data
    self.revision = revision
  }
}

public protocol GlobalAuthorityStorage: Sendable {
  func load() async throws -> GlobalAuthorityStorageSnapshot
  func save(
    _ data: Data,
    replacing expectedRevision: GlobalAuthorityStorageRevision
  ) async throws -> GlobalAuthorityStorageRevision
}

public actor InMemoryGlobalAuthorityStorage: GlobalAuthorityStorage {
  private var data: Data?

  public init(data: Data? = nil) {
    self.data = data
  }

  public func load() -> GlobalAuthorityStorageSnapshot {
    GlobalAuthorityStorageSnapshot(
      data: data,
      revision: .current(for: data)
    )
  }

  public func save(
    _ data: Data,
    replacing expectedRevision: GlobalAuthorityStorageRevision
  ) throws -> GlobalAuthorityStorageRevision {
    guard GlobalAuthorityStorageRevision.current(for: self.data) == expectedRevision else {
      throw GlobalAuthorityRepositoryError.staleStorageRevision
    }
    self.data = data
    return .current(for: data)
  }
}

public actor FileGlobalAuthorityStorage: GlobalAuthorityStorage {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL.standardizedFileURL
  }

  public func load() async throws -> GlobalAuthorityStorageSnapshot {
    try await GlobalAuthorityFileCommitCoordinator.shared.load(
      fileURL: fileURL
    )
  }

  public func save(
    _ data: Data,
    replacing expectedRevision: GlobalAuthorityStorageRevision
  ) async throws -> GlobalAuthorityStorageRevision {
    try await GlobalAuthorityFileCommitCoordinator.shared.save(
      data,
      fileURL: fileURL,
      replacing: expectedRevision
    )
  }
}

private actor GlobalAuthorityFileCommitCoordinator {
  static let shared = GlobalAuthorityFileCommitCoordinator()

  private let fileManager = FileManager.default

  func load(
    fileURL: URL
  ) throws -> GlobalAuthorityStorageSnapshot {
    try ProtectedAtomicFile.removeOrphanedStagingFiles(
      for: fileURL,
      fileManager: fileManager
    )
    let data =
      fileManager.fileExists(atPath: fileURL.path)
      ? try Data(contentsOf: fileURL)
      : nil
    return GlobalAuthorityStorageSnapshot(
      data: data,
      revision: .current(for: data)
    )
  }

  func save(
    _ data: Data,
    fileURL: URL,
    replacing expectedRevision: GlobalAuthorityStorageRevision
  ) throws -> GlobalAuthorityStorageRevision {
    try ProtectedAtomicFile.removeOrphanedStagingFiles(
      for: fileURL,
      fileManager: fileManager
    )
    let currentData =
      fileManager.fileExists(atPath: fileURL.path)
      ? try Data(contentsOf: fileURL)
      : nil
    guard GlobalAuthorityStorageRevision.current(for: currentData) == expectedRevision else {
      throw GlobalAuthorityRepositoryError.staleStorageRevision
    }
    try ProtectedAtomicFile.write(data, to: fileURL)
    return .current(for: data)
  }
}

public actor GlobalAuthorityRepository<Storage: GlobalAuthorityStorage> {
  private let storage: Storage
  private let initialSnapshot: GlobalAuthoritySnapshot
  private let codec: GlobalAuthorityCodec
  private var cached: GlobalAuthoritySnapshot?
  private var storageRevision: GlobalAuthorityStorageRevision?
  private var operationIsActive = false
  private var operationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    storage: Storage,
    initialSnapshot: GlobalAuthoritySnapshot,
    codec: GlobalAuthorityCodec = GlobalAuthorityCodec()
  ) throws {
    guard initialSnapshot.isValid else {
      throw GlobalAuthorityCodecError.invalidSnapshot
    }
    self.storage = storage
    self.initialSnapshot = initialSnapshot
    self.codec = codec
  }

  public func current() async throws -> GlobalAuthoritySnapshot {
    await acquireOperation()
    defer { releaseOperation() }
    return try await loadLatest()
  }

  @discardableResult
  public func merge(
    preferences incoming: GlobalSyncedPreferences
  ) async throws -> GlobalPreferenceMergeResult {
    await acquireOperation()
    defer { releaseOperation() }

    let current = try await loadLatest()
    let result = GlobalPreferenceMerger.merge(
      current: current.preferences,
      incoming: incoming
    )
    guard case .applied(let preferences) = result else { return result }
    let updatedRoot =
      preferences.profileSelection.profile.deletionAuthorityRoot
    let consent =
      updatedRoot == current.deletionRoot
      ? current.consent
      : .disabled(
        revision: updatedRoot.epoch.revision,
        authorDevice: .phone
      )
    let updated = GlobalAuthoritySnapshot(
      preferences: preferences,
      consent: consent
    )
    try await persist(updated)
    return result
  }

  @discardableResult
  public func merge(
    consent incoming: GlobalConsentState,
    deletionRoot incomingRoot: DeletionAuthorityRoot
  ) async throws -> GlobalConsentMergeResult {
    await acquireOperation()
    defer { releaseOperation() }

    let current = try await loadLatest()
    let currentRoot = current.deletionRoot
    guard incomingRoot.isValid else {
      _ = try await persistFailClosedConsentRevocation(from: current)
      throw GlobalAuthorityCodecError.invalidSnapshot
    }
    if incomingRoot != currentRoot {
      let failClosed = try await persistFailClosedConsentRevocation(
        from: current
      )
      if incomingRoot < currentRoot {
        return .duplicate(failClosed.consent)
      }
      throw GlobalAuthorityRepositoryError.deletionRootMismatch(
        expected: currentRoot,
        received: incomingRoot
      )
    }
    let result = GlobalConsentMerger.merge(
      current: current.consent,
      incoming: incoming
    )
    guard case .applied(let consent) = result else { return result }
    let updated = GlobalAuthoritySnapshot(
      preferences: current.preferences,
      consent: consent
    )
    try await persist(updated)
    return result
  }

  /// Revokes every capability when a peer cannot prove the same consent root.
  ///
  /// Each record keeps its causal revision. The restrictive equal-revision
  /// merge rule means replaying the former enabled value cannot reopen it.
  @discardableResult
  public func revokeConsentForIncompatiblePeer() async throws -> Bool {
    await acquireOperation()
    defer { releaseOperation() }

    let current = try await loadLatest()
    let revoked = try await persistFailClosedConsentRevocation(from: current)
    return revoked != current
  }

  /// Atomically replaces content-bearing authority with a newer deletion
  /// fence. Ordinary preference/consent changes must continue to use `merge`.
  func replaceForDeletion(
    with replacement: GlobalAuthoritySnapshot
  ) async throws {
    await acquireOperation()
    defer { releaseOperation() }

    let current = try await loadLatest()
    let currentProfile = current.preferences.profileSelection.profile
    let replacementProfile = replacement.preferences.profileSelection.profile
    guard
      replacement.isValid,
      replacementProfile.deletionAuthorityRoot
        > currentProfile.deletionAuthorityRoot,
      replacement.preferences.companionSensing.value.enabled == false,
      MoriConsentKind.allCases.allSatisfy({
        replacement.consent[$0].enabled == false
      })
    else {
      throw GlobalAuthorityCodecError.invalidSnapshot
    }
    try await persist(replacement)
  }

  private func acquireOperation() async {
    guard operationIsActive else {
      operationIsActive = true
      return
    }
    await withCheckedContinuation { continuation in
      operationWaiters.append(continuation)
    }
  }

  private func releaseOperation() {
    guard !operationWaiters.isEmpty else {
      operationIsActive = false
      return
    }
    operationWaiters.removeFirst().resume()
  }

  private func loadLatest() async throws -> GlobalAuthoritySnapshot {
    let stored = try await storage.load()
    if let cached, stored.revision == storageRevision {
      return cached
    }
    let snapshot: GlobalAuthoritySnapshot
    if let data = stored.data {
      snapshot = try codec.decode(data)
      let normalizedData = try codec.encode(snapshot)
      if normalizedData != data {
        do {
          storageRevision = try await storage.save(
            normalizedData,
            replacing: stored.revision
          )
        } catch {
          cached = nil
          storageRevision = nil
          throw error
        }
      } else {
        storageRevision = stored.revision
      }
    } else {
      snapshot = initialSnapshot
      storageRevision = stored.revision
    }
    cached = snapshot
    return snapshot
  }

  private func persist(_ snapshot: GlobalAuthoritySnapshot) async throws {
    guard let storageRevision else {
      throw GlobalAuthorityRepositoryError.staleStorageRevision
    }
    let data = try codec.encode(snapshot)
    do {
      self.storageRevision = try await storage.save(
        data,
        replacing: storageRevision
      )
      cached = snapshot
    } catch {
      cached = nil
      self.storageRevision = nil
      throw error
    }
  }

  private func persistFailClosedConsentRevocation(
    from current: GlobalAuthoritySnapshot
  ) async throws -> GlobalAuthoritySnapshot {
    var consent = current.consent
    for kind in MoriConsentKind.allCases {
      let record = consent[kind]
      consent = consent.replacing(
        kind,
        with: MoriConsentRecord(
          enabled: false,
          disclosureVersion: 0,
          revision: record.revision,
          authorDevice: record.authorDevice
        )
      )
    }
    guard consent != current.consent else { return current }
    let revoked = GlobalAuthoritySnapshot(
      preferences: current.preferences,
      consent: consent
    )
    try await persist(revoked)
    return revoked
  }
}
