import Foundation
import MoriDomain

public protocol ProfileLedgerStorage: Sendable {
  func load() async throws -> Data?
  func save(_ data: Data) async throws
}

public actor InMemoryProfileLedgerStorage: ProfileLedgerStorage {
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

/// The caller supplies a profile/epoch-specific, app-private URL. Atomic
/// replacement and Apple data protection prevent a partial ledger from being
/// accepted after interruption.
public actor FileProfileLedgerStorage: ProfileLedgerStorage {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try Data(contentsOf: fileURL)
  }

  public func save(_ data: Data) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: [.atomic])

    var protectedURL = fileURL
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try protectedURL.setResourceValues(values)

    #if os(iOS) || os(watchOS) || os(tvOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: fileURL.path
      )
    #endif
  }
}

public actor ProfileLedgerRepository<Storage: ProfileLedgerStorage> {
  private let storage: Storage
  private let initialState: ProfileState
  private let codec: ProfileLedgerCodec
  private var cached: ProfileLedger?

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
    try await loadIfNeeded()
  }

  public func currentReplay() async throws -> ProfileReplayResult {
    try await loadIfNeeded().replay()
  }

  @discardableResult
  public func append(_ envelope: ExperienceSyncEnvelope) async throws -> ProfileReplayResult {
    var ledger = try await loadIfNeeded()
    try ledger.append(envelope)
    try await storage.save(codec.encode(ledger))
    cached = ledger
    return ledger.replay()
  }

  public func replace(with replacement: ProfileLedger) async throws {
    guard
      replacement.initialState.runtimeProfile == initialState.runtimeProfile
    else {
      throw ProfileLedgerError.envelopeProfileMismatch(
        ExperienceEventID("repository-initial-profile")
      )
    }
    try await storage.save(codec.encode(replacement))
    cached = replacement
  }

  private func loadIfNeeded() async throws -> ProfileLedger {
    if let cached { return cached }
    let loaded: ProfileLedger
    if let data = try await storage.load() {
      loaded = try codec.decode(data)
      guard loaded.initialState.runtimeProfile == initialState.runtimeProfile else {
        throw ProfileLedgerError.envelopeProfileMismatch(
          ExperienceEventID("repository-loaded-profile")
        )
      }
    } else {
      loaded = try ProfileLedger(initialState: initialState)
    }
    cached = loaded
    return loaded
  }
}
