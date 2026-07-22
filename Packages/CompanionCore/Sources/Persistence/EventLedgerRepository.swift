import Domain
import Foundation
import Growth

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
  }
}

/// Serializes append, persistence, and state replay so Watch and phone callers cannot observe a
/// persisted event that is missing from the returned state (or the inverse).
public actor EventLedgerRepository<Storage: EventLedgerStorage> {
  private let storage: Storage
  private let codec: EventLedgerCodec
  private let reducer: CompanionReducer
  private var ledger: EventLedger?

  public init(
    storage: Storage,
    codec: EventLedgerCodec = EventLedgerCodec(),
    reducer: CompanionReducer = CompanionReducer()
  ) {
    self.storage = storage
    self.codec = codec
    self.reducer = reducer
  }

  public func currentLedger() async throws -> EventLedger {
    try await loadIfNeeded()
  }

  public func currentState(from initialState: CompanionState = CompanionState()) async throws
    -> CompanionState
  {
    let ledger = try await loadIfNeeded()
    return try reducer.replay(ledger.events, from: initialState)
  }

  @discardableResult
  public func append(
    _ event: EventEnvelope,
    from initialState: CompanionState = CompanionState()
  ) async throws -> CompanionState {
    var updatedLedger = try await loadIfNeeded()
    try updatedLedger.append(event)
    try await storage.save(codec.encode(updatedLedger))
    ledger = updatedLedger
    return try reducer.replay(updatedLedger.events, from: initialState)
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
