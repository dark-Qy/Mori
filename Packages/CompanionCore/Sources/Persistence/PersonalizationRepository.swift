import Domain
import Foundation

public enum PersonalizationPersistenceError: Error, Equatable {
  case malformedEnvelope
  case migrationUnavailable(from: Int, to: Int)
  case unsupportedFutureSchema(Int)
  case unsupportedStateSchema(Int)
}

public struct PersistedPersonalizationState: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var state: PersonalizationState

  public init(
    schemaVersion: Int = PersistedPersonalizationState.currentSchemaVersion,
    state: PersonalizationState
  ) {
    self.schemaVersion = schemaVersion
    self.state = state
  }
}

public protocol PersonalizationStateMigrating: Sendable {
  func migrate(_ data: Data, from sourceVersion: Int, to targetVersion: Int) throws -> Data
}

public struct PersonalizationStateCodec: Sendable {
  private struct SchemaHeader: Decodable {
    var schemaVersion: Int
  }

  public init() {}

  public func encode(_ state: PersonalizationState) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(PersistedPersonalizationState(state: state))
  }

  public func decode(
    _ data: Data,
    migrator: (any PersonalizationStateMigrating)? = nil
  ) throws -> PersonalizationState {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    guard let header = try? decoder.decode(SchemaHeader.self, from: data) else {
      throw PersonalizationPersistenceError.malformedEnvelope
    }

    let currentVersion = PersistedPersonalizationState.currentSchemaVersion
    if header.schemaVersion > currentVersion {
      throw PersonalizationPersistenceError.unsupportedFutureSchema(header.schemaVersion)
    }
    if header.schemaVersion < currentVersion {
      guard let migrator else {
        throw PersonalizationPersistenceError.migrationUnavailable(
          from: header.schemaVersion,
          to: currentVersion
        )
      }
      return try decode(
        migrator.migrate(
          data,
          from: header.schemaVersion,
          to: currentVersion
        )
      )
    }
    guard let envelope = try? decoder.decode(PersistedPersonalizationState.self, from: data) else {
      throw PersonalizationPersistenceError.malformedEnvelope
    }
    guard envelope.state.schemaVersion == PersonalizationState.currentSchemaVersion else {
      throw PersonalizationPersistenceError.unsupportedStateSchema(envelope.state.schemaVersion)
    }
    return envelope.state
  }
}

public protocol PersonalizationStorage: Sendable {
  func load() async throws -> Data?
  func save(_ data: Data) async throws
}

public actor InMemoryPersonalizationStorage: PersonalizationStorage {
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

/// The caller supplies an app-private Application Support URL. Learned evidence is excluded from
/// backup and protected after first unlock, matching the existing event-ledger privacy boundary.
public actor FilePersonalizationStorage: PersonalizationStorage {
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

/// The app-facing boundary intentionally offers no arbitrary or AI-authored memory write.
/// Only typed, concrete PersonalizationSignal values can reinforce learned state.
public protocol PersonalizationRepositoryProtocol: Sendable {
  func state(at date: Date) async throws -> PersonalizationState
  func projection(at date: Date) async throws -> MoriPersonalityProjection
  func record(_ signal: PersonalizationSignal, at date: Date) async throws
  func setEnabled(_ enabled: Bool) async throws
  func clearLearnedData() async throws
}

public actor PersonalizationRepository<Storage: PersonalizationStorage>:
  PersonalizationRepositoryProtocol
{
  private let storage: Storage
  private let codec: PersonalizationStateCodec
  private let engine: PersonalizationEngine
  private var cachedState: PersonalizationState?
  private var isOperating = false
  private var operationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    storage: Storage,
    codec: PersonalizationStateCodec = PersonalizationStateCodec(),
    engine: PersonalizationEngine = PersonalizationEngine()
  ) {
    self.storage = storage
    self.codec = codec
    self.engine = engine
  }

  public func state(at date: Date) async throws -> PersonalizationState {
    await beginExclusiveOperation()
    defer { endExclusiveOperation() }
    let current = try await loadIfNeeded()
    let maintained = engine.maintaining(current, at: date)
    if maintained != current {
      try await persist(maintained)
    }
    return maintained
  }

  public func projection(at date: Date) async throws -> MoriPersonalityProjection {
    try await state(at: date).compactProjection
  }

  public func record(_ signal: PersonalizationSignal, at date: Date) async throws {
    await beginExclusiveOperation()
    defer { endExclusiveOperation() }
    let current = try await loadIfNeeded()
    let updated = engine.recording(signal, in: current, at: date)
    guard updated != current else { return }
    try await persist(updated)
  }

  public func setEnabled(_ enabled: Bool) async throws {
    await beginExclusiveOperation()
    defer { endExclusiveOperation() }
    var updated = try await loadIfNeeded()
    guard updated.isEnabled != enabled else { return }
    updated.isEnabled = enabled
    try await persist(updated)
  }

  /// Removes all learned evidence and adaptive traits while preserving the privacy toggle.
  public func clearLearnedData() async throws {
    await beginExclusiveOperation()
    defer { endExclusiveOperation() }
    let current = try await loadIfNeeded()
    try await persist(PersonalizationState(isEnabled: current.isEnabled))
  }

  /// Actor isolation alone does not serialize across storage awaits: another actor entry can run
  /// while load/save is suspended. This FIFO gate makes each read-maintain-write or mutation a
  /// linearizable repository operation.
  private func beginExclusiveOperation() async {
    guard isOperating else {
      isOperating = true
      return
    }
    await withCheckedContinuation { continuation in
      operationWaiters.append(continuation)
    }
  }

  private func endExclusiveOperation() {
    guard !operationWaiters.isEmpty else {
      isOperating = false
      return
    }
    operationWaiters.removeFirst().resume()
  }

  private func loadIfNeeded() async throws -> PersonalizationState {
    if let cachedState { return cachedState }
    let loaded: PersonalizationState
    if let data = try await storage.load() {
      loaded = try codec.decode(data)
    } else {
      loaded = PersonalizationState()
    }
    cachedState = loaded
    return loaded
  }

  private func persist(_ state: PersonalizationState) async throws {
    try await storage.save(codec.encode(state))
    cachedState = state
  }
}

extension PersonalizationRepositoryProtocol {
  public func state() async throws -> PersonalizationState {
    try await state(at: Date())
  }

  public func projection() async throws -> MoriPersonalityProjection {
    try await projection(at: Date())
  }

  public func record(_ signal: PersonalizationSignal) async throws {
    try await record(signal, at: Date())
  }
}
