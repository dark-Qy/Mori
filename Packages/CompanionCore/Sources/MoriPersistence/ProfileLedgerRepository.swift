import CryptoKit
import Foundation
import MoriDomain

public enum ProfileLedgerStorageRevision: Hashable, Sendable {
  case absent
  case digest(String)

  public static func current(for data: Data?) -> Self {
    guard let data else { return .absent }
    let digest = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    return .digest(digest)
  }
}

public struct ProfileLedgerStorageSnapshot: Sendable {
  public let data: Data?
  public let revision: ProfileLedgerStorageRevision

  public init(
    data: Data?,
    revision: ProfileLedgerStorageRevision
  ) {
    self.data = data
    self.revision = revision
  }
}

public enum ProfileLedgerStorageError: Error, Equatable, Sendable {
  case staleRevision
}

public protocol ProfileLedgerStorage: Sendable {
  func load() async throws -> ProfileLedgerStorageSnapshot
  func save(
    _ data: Data,
    replacing expectedRevision: ProfileLedgerStorageRevision
  ) async throws -> ProfileLedgerStorageRevision
}

public actor InMemoryProfileLedgerStorage: ProfileLedgerStorage {
  private var data: Data?

  public init(data: Data? = nil) {
    self.data = data
  }

  public func load() -> ProfileLedgerStorageSnapshot {
    ProfileLedgerStorageSnapshot(
      data: data,
      revision: .current(for: data)
    )
  }

  public func save(
    _ data: Data,
    replacing expectedRevision: ProfileLedgerStorageRevision
  ) throws -> ProfileLedgerStorageRevision {
    guard ProfileLedgerStorageRevision.current(for: self.data) == expectedRevision else {
      throw ProfileLedgerStorageError.staleRevision
    }
    self.data = data
    return .current(for: data)
  }
}

/// The caller supplies a profile/epoch-specific, app-private URL. A shared
/// commit actor makes compare-and-swap atomic across every in-process storage
/// instance that resolves to the same standardized file URL.
public actor FileProfileLedgerStorage: ProfileLedgerStorage {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL.standardizedFileURL
  }

  public func load() async throws -> ProfileLedgerStorageSnapshot {
    try await ProfileLedgerFileCommitCoordinator.shared.load(
      fileURL: fileURL
    )
  }

  public func save(
    _ data: Data,
    replacing expectedRevision: ProfileLedgerStorageRevision
  ) async throws -> ProfileLedgerStorageRevision {
    try await ProfileLedgerFileCommitCoordinator.shared.save(
      data,
      fileURL: fileURL,
      replacing: expectedRevision
    )
  }
}

private actor ProfileLedgerFileCommitCoordinator {
  static let shared = ProfileLedgerFileCommitCoordinator()

  private let fileManager = FileManager.default

  func load(fileURL: URL) throws -> ProfileLedgerStorageSnapshot {
    let data =
      fileManager.fileExists(atPath: fileURL.path)
      ? try Data(contentsOf: fileURL)
      : nil
    return ProfileLedgerStorageSnapshot(
      data: data,
      revision: .current(for: data)
    )
  }

  func save(
    _ data: Data,
    fileURL: URL,
    replacing expectedRevision: ProfileLedgerStorageRevision
  ) throws -> ProfileLedgerStorageRevision {
    let currentData =
      fileManager.fileExists(atPath: fileURL.path)
      ? try Data(contentsOf: fileURL)
      : nil
    guard ProfileLedgerStorageRevision.current(for: currentData) == expectedRevision else {
      throw ProfileLedgerStorageError.staleRevision
    }

    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: [.atomic])

    var protectedURL = fileURL
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try protectedURL.setResourceValues(values)

    #if os(iOS) || os(watchOS) || os(tvOS)
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: fileURL.path
      )
    #endif

    return .current(for: data)
  }
}

public actor ProfileLedgerRepository<Storage: ProfileLedgerStorage> {
  private static var maximumCommitAttempts: Int { 8 }

  private let storage: Storage
  private let initialState: ProfileState
  private let codec: ProfileLedgerCodec
  private var operationIsActive = false
  private var operationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    storage: Storage,
    initialState: ProfileState,
    codec: ProfileLedgerCodec = ProfileLedgerCodec()
  ) {
    self.storage = storage
    self.initialState = initialState
    self.codec = codec
  }

  public func currentLedger() async throws -> ProfileLedger {
    await acquireOperation()
    defer { releaseOperation() }
    return try await loadPersistingMigration()
  }

  public func currentReplay() async throws -> ProfileReplayResult {
    await acquireOperation()
    defer { releaseOperation() }
    return try await loadPersistingMigration().replay()
  }

  @discardableResult
  public func append(
    _ envelope: ExperienceSyncEnvelope
  ) async throws -> ProfileReplayResult {
    await acquireOperation()
    defer { releaseOperation() }

    for _ in 0..<Self.maximumCommitAttempts {
      let loaded = try await loadLatest()
      var ledger = loaded.ledger
      try ledger.append(envelope)
      do {
        _ = try await storage.save(
          codec.encode(ledger),
          replacing: loaded.revision
        )
        return ledger.replay()
      } catch ProfileLedgerStorageError.staleRevision {
        continue
      }
    }
    throw ProfileLedgerStorageError.staleRevision
  }

  /// Persists the sensing authority before any caller can admit facts for the
  /// new epoch. A CAS conflict reloads and reapplies the same mutation to the
  /// latest envelope set.
  @discardableResult
  public func setCompanionSensing(
    enabled: Bool,
    epoch: SensingEpoch,
    effectiveAt: Date
  ) async throws -> MutationResult {
    await acquireOperation()
    defer { releaseOperation() }

    for _ in 0..<Self.maximumCommitAttempts {
      let loaded = try await loadLatest()
      var ledger = loaded.ledger
      let result = ledger.setCompanionSensing(
        enabled: enabled,
        epoch: epoch,
        effectiveAt: effectiveAt
      )
      guard case .applied = result else { return result }
      do {
        _ = try await storage.save(
          codec.encode(ledger),
          replacing: loaded.revision
        )
        return result
      } catch ProfileLedgerStorageError.staleRevision {
        continue
      }
    }
    throw ProfileLedgerStorageError.staleRevision
  }

  public func replace(with replacement: ProfileLedger) async throws {
    await acquireOperation()
    defer { releaseOperation() }

    guard
      replacement.initialState.runtimeProfile == initialState.runtimeProfile
    else {
      throw ProfileLedgerError.envelopeProfileMismatch(
        ExperienceEventID("repository-initial-profile")
      )
    }
    let replacementData = try codec.encode(replacement)
    for _ in 0..<Self.maximumCommitAttempts {
      let stored = try await storage.load()
      do {
        _ = try await storage.save(
          replacementData,
          replacing: stored.revision
        )
        return
      } catch ProfileLedgerStorageError.staleRevision {
        continue
      }
    }
    throw ProfileLedgerStorageError.staleRevision
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

  private func loadPersistingMigration() async throws -> ProfileLedger {
    for _ in 0..<Self.maximumCommitAttempts {
      let loaded = try await loadLatest()
      guard loaded.requiresMigration else {
        return loaded.ledger
      }
      do {
        _ = try await storage.save(
          codec.encode(loaded.ledger),
          replacing: loaded.revision
        )
        return loaded.ledger
      } catch ProfileLedgerStorageError.staleRevision {
        continue
      }
    }
    throw ProfileLedgerStorageError.staleRevision
  }

  private func loadLatest() async throws -> LoadedProfileLedger {
    let stored = try await storage.load()
    let ledger: ProfileLedger
    let requiresMigration: Bool
    if let data = stored.data {
      ledger = try codec.decode(data)
      guard ledger.initialState.runtimeProfile == initialState.runtimeProfile else {
        throw ProfileLedgerError.envelopeProfileMismatch(
          ExperienceEventID("repository-loaded-profile")
        )
      }
      requiresMigration = try codec.encode(ledger) != data
    } else {
      ledger = try ProfileLedger(initialState: initialState)
      requiresMigration = false
    }
    return LoadedProfileLedger(
      ledger: ledger,
      revision: stored.revision,
      requiresMigration: requiresMigration
    )
  }
}

private struct LoadedProfileLedger: Sendable {
  let ledger: ProfileLedger
  let revision: ProfileLedgerStorageRevision
  let requiresMigration: Bool
}
