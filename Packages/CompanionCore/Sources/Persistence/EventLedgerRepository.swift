import Domain
import Foundation

public protocol EventLedgerStorage: Sendable {
  func load() async throws -> Data?
  func save(_ data: Data) async throws
}

public actor InMemoryEventLedgerStorage: EventLedgerStorage {
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

/// Stores a single encoded event ledger. Atomic replacement prevents a partially written ledger
/// from looking valid after interruption. The caller chooses an app-private URL.
public actor FileEventLedgerStorage: EventLedgerStorage {
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

    // The ledger can contain health-derived decisions. Keep it out of device backups and use
    // data protection on Apple mobile platforms while still allowing post-unlock background work.
    var protectedURL = fileURL
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try protectedURL.setResourceValues(resourceValues)

    #if os(iOS) || os(watchOS) || os(tvOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: fileURL.path
      )
    #endif
  }
}

/// Serializes append and persistence so concurrent Watch and phone callbacks cannot overwrite
/// one another. State replay remains in the Growth layer to preserve dependency direction.
public actor EventLedgerRepository<Storage: EventLedgerStorage> {
  private let storage: Storage
  private let codec: EventLedgerCodec
  private var ledger: EventLedger?

  public init(
    storage: Storage,
    codec: EventLedgerCodec = EventLedgerCodec()
  ) {
    self.storage = storage
    self.codec = codec
  }

  public func currentLedger() async throws -> EventLedger {
    try await loadIfNeeded()
  }

  @discardableResult
  public func append(_ event: EventEnvelope) async throws -> EventLedger {
    var updatedLedger = try await loadIfNeeded()
    try updatedLedger.append(event)
    try await storage.save(codec.encode(updatedLedger))
    ledger = updatedLedger
    return updatedLedger
  }

  public func replace(with replacement: EventLedger) async throws {
    try await storage.save(codec.encode(replacement))
    ledger = replacement
  }

  private func loadIfNeeded() async throws -> EventLedger {
    if let ledger { return ledger }
    let loaded: EventLedger
    if let data = try await storage.load() {
      loaded = try codec.decode(data)
    } else {
      loaded = try EventLedger()
    }
    ledger = loaded
    return loaded
  }
}
