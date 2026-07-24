import Foundation
import MoriDomain
import MoriPersistence

public protocol ExperienceSyncOutboxStorage: Sendable {
  func load() async throws -> Data?
  func save(_ data: Data) async throws
}

public actor InMemoryExperienceSyncOutboxStorage: ExperienceSyncOutboxStorage {
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

public actor FileExperienceSyncOutboxStorage: ExperienceSyncOutboxStorage {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try Data(contentsOf: fileURL)
  }

  public func save(_ data: Data) throws {
    try ProtectedAtomicFile.write(data, to: fileURL)
  }
}

private struct ExperienceSyncOutboxEntry: Codable, Equatable, Sendable {
  let eventID: ExperienceEventID
  let envelopeBytes: Data
}

private struct ExperienceSyncOutboxDocument: Codable, Equatable, Sendable {
  static let currentSchemaVersion: UInt16 = 1

  var schemaVersion: UInt16
  var scope: ExperienceSyncScope
  var entries: [ExperienceSyncOutboxEntry]
  var acknowledgedEventIDs: [ExperienceEventID]

  init(scope: ExperienceSyncScope) {
    schemaVersion = Self.currentSchemaVersion
    self.scope = scope
    entries = []
    acknowledgedEventIDs = []
  }
}

public enum ExperienceSyncOutboxError: Error, Equatable, Sendable {
  case oversizedPersistedDocument(actualBytes: Int, maximumBytes: Int)
  case malformedPersistedDocument
  case nonCanonicalPersistedDocument
  case unsupportedSchema(UInt16)
  case invalidScope
  case persistedScopeMismatch
  case envelopeScopeMismatch(ExperienceEventID)
  case conflictingEventID(ExperienceEventID)
  case duplicatePersistedEventID(ExperienceEventID)
  case acknowledgementScopeMismatch
  case acknowledgementForUnsentEvent(ExperienceEventID)
}

/// Durable append-only delivery queue. Acknowledgement removes only the exact
/// stable event IDs that the peer persisted. Failed sends leave the original
/// canonical envelope bytes untouched for retry after offline or relaunch.
public actor ExperienceSyncOutbox<Storage: ExperienceSyncOutboxStorage> {
  public static var defaultMaximumTransferPayloadBytes: Int { 300 * 1_024 }
  public static var defaultMaximumDocumentBytes: Int { 2 * 1_024 * 1_024 }

  private let storage: Storage
  private let scope: ExperienceSyncScope
  private let codec: CanonicalJSONCodec
  private let envelopeCodec: ExperienceEnvelopeCodec
  private let maximumDocumentBytes: Int
  private var cachedDocument: ExperienceSyncOutboxDocument?
  private var operationIsActive = false
  private var operationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    storage: Storage,
    profile: RuntimeProfile,
    codec: CanonicalJSONCodec = CanonicalJSONCodec(),
    envelopeCodec: ExperienceEnvelopeCodec = ExperienceEnvelopeCodec(),
    maximumDocumentBytes: Int = defaultMaximumDocumentBytes
  ) {
    self.storage = storage
    scope = ExperienceSyncScope(profile: profile)
    self.codec = codec
    self.envelopeCodec = envelopeCodec
    self.maximumDocumentBytes = max(1, maximumDocumentBytes)
  }

  public func enqueue(_ envelope: ExperienceSyncEnvelope) async throws {
    try await reconcile([envelope])
  }

  /// Repairs the crash boundary between the profile ledger and this outbox.
  /// Acknowledged IDs stay as small delivery markers so relaunch does not
  /// repeatedly re-enqueue the complete append-only ledger.
  public func reconcile(_ envelopes: [ExperienceSyncEnvelope]) async throws {
    await acquireOperation()
    defer { releaseOperation() }

    guard scope.isValid else {
      throw ExperienceSyncOutboxError.invalidScope
    }
    var document = try await loadDocument()
    let acknowledged = Set(document.acknowledgedEventIDs)
    var changed = false
    for envelope in envelopes {
      guard scope.contains(envelope) else {
        throw ExperienceSyncOutboxError.envelopeScopeMismatch(envelope.eventID)
      }
      let bytes = try envelopeCodec.encode(envelope)
      if let existing = document.entries.first(where: { $0.eventID == envelope.eventID }) {
        guard existing.envelopeBytes == bytes else {
          throw ExperienceSyncOutboxError.conflictingEventID(envelope.eventID)
        }
        continue
      }
      guard acknowledged.contains(envelope.eventID) == false else { continue }
      document.entries.append(
        ExperienceSyncOutboxEntry(eventID: envelope.eventID, envelopeBytes: bytes)
      )
      changed = true
    }
    if changed {
      try await persist(document)
    }
  }

  public func pendingCount() async throws -> Int {
    await acquireOperation()
    defer { releaseOperation() }
    return try await loadDocument().entries.count
  }

  public func pendingTransfer(
    limit: Int = 64,
    maximumPayloadBytes: Int = defaultMaximumTransferPayloadBytes
  ) async throws -> ExperienceSyncTransfer? {
    await acquireOperation()
    defer { releaseOperation() }

    let document = try await loadDocument()
    guard document.entries.isEmpty == false else { return nil }
    let boundedLimit = max(1, limit)
    let boundedBytes = max(1, maximumPayloadBytes)
    let ordered = try document.entries
      .map { entry -> (ExperienceSyncEnvelope, Data) in
        (try envelopeCodec.decode(entry.envelopeBytes), entry.envelopeBytes)
      }
      .sorted { ProfileLedger.canonicalOrder($0.0, $1.0) }
    var entries: [(ExperienceSyncEnvelope, Data)] = []
    var byteCount = 0
    for entry in ordered.prefix(boundedLimit) {
      let nextByteCount = byteCount + entry.1.count
      if entries.isEmpty == false, nextByteCount > boundedBytes { break }
      entries.append(entry)
      byteCount = nextByteCount
    }
    return ExperienceSyncTransfer(
      scope: scope,
      envelopeBytes: entries.map(\.1)
    )
  }

  public func acknowledge(
    _ acknowledgement: ExperienceSyncAcknowledgement,
    sentEventIDs: Set<ExperienceEventID>
  ) async throws {
    await acquireOperation()
    defer { releaseOperation() }

    guard acknowledgement.scope == scope else {
      throw ExperienceSyncOutboxError.acknowledgementScopeMismatch
    }
    let resolved = Set(
      acknowledgement.eventIDs + acknowledgement.terminalRejections.map(\.eventID)
    )
    for eventID in resolved where sentEventIDs.contains(eventID) == false {
      throw ExperienceSyncOutboxError.acknowledgementForUnsentEvent(eventID)
    }

    var document = try await loadDocument()
    document.entries.removeAll { resolved.contains($0.eventID) }
    document.acknowledgedEventIDs = Array(
      Set(document.acknowledgedEventIDs).union(resolved)
    ).sorted()
    try await persist(document)
  }

  /// Records that these IDs arrived from the paired peer. They are already
  /// present on that peer, so ledger reconciliation must not echo them back.
  /// If the same stable event was also pending locally, the peer delivery is
  /// its acknowledgement and removes that exact pending copy.
  public func markPeerDelivered(
    _ envelopes: [ExperienceSyncEnvelope]
  ) async throws {
    await acquireOperation()
    defer { releaseOperation() }

    var document = try await loadDocument()
    var delivered = Set(document.acknowledgedEventIDs)
    for envelope in envelopes {
      guard scope.contains(envelope) else {
        throw ExperienceSyncOutboxError.envelopeScopeMismatch(envelope.eventID)
      }
      let bytes = try envelopeCodec.encode(envelope)
      if let existing = document.entries.first(where: { $0.eventID == envelope.eventID }) {
        guard existing.envelopeBytes == bytes else {
          throw ExperienceSyncOutboxError.conflictingEventID(envelope.eventID)
        }
      }
      delivered.insert(envelope.eventID)
    }
    let deliveredIDs = Set(envelopes.map(\.eventID))
    document.entries.removeAll { deliveredIDs.contains($0.eventID) }
    document.acknowledgedEventIDs = delivered.sorted()
    try await persist(document)
  }

  private func loadDocument() async throws -> ExperienceSyncOutboxDocument {
    if let cachedDocument { return cachedDocument }
    guard let data = try await storage.load() else {
      let document = ExperienceSyncOutboxDocument(scope: scope)
      cachedDocument = document
      return document
    }
    guard data.count <= maximumDocumentBytes else {
      throw ExperienceSyncOutboxError.oversizedPersistedDocument(
        actualBytes: data.count,
        maximumBytes: maximumDocumentBytes
      )
    }
    let document: ExperienceSyncOutboxDocument
    let canonicalData: Data
    do {
      document = try codec.decode(
        ExperienceSyncOutboxDocument.self,
        from: data
      )
      canonicalData = try codec.encode(document)
    } catch {
      throw ExperienceSyncOutboxError.malformedPersistedDocument
    }
    guard data == canonicalData else {
      throw ExperienceSyncOutboxError.nonCanonicalPersistedDocument
    }
    guard document.schemaVersion == ExperienceSyncOutboxDocument.currentSchemaVersion else {
      throw ExperienceSyncOutboxError.unsupportedSchema(document.schemaVersion)
    }
    guard document.scope.isValid else {
      throw ExperienceSyncOutboxError.invalidScope
    }
    guard document.scope == scope else {
      throw ExperienceSyncOutboxError.persistedScopeMismatch
    }

    var seen: Set<ExperienceEventID> = []
    for entry in document.entries {
      guard seen.insert(entry.eventID).inserted else {
        throw ExperienceSyncOutboxError.duplicatePersistedEventID(entry.eventID)
      }
      let envelope = try envelopeCodec.decode(entry.envelopeBytes)
      guard envelope.eventID == entry.eventID, scope.contains(envelope) else {
        throw ExperienceSyncOutboxError.envelopeScopeMismatch(entry.eventID)
      }
    }
    var acknowledged: Set<ExperienceEventID> = []
    for eventID in document.acknowledgedEventIDs {
      guard eventID.isValid else {
        throw ExperienceSyncOutboxError.duplicatePersistedEventID(eventID)
      }
      guard acknowledged.insert(eventID).inserted else {
        throw ExperienceSyncOutboxError.duplicatePersistedEventID(eventID)
      }
      guard seen.contains(eventID) == false else {
        throw ExperienceSyncOutboxError.duplicatePersistedEventID(eventID)
      }
    }
    cachedDocument = document
    return document
  }

  private func persist(_ document: ExperienceSyncOutboxDocument) async throws {
    let data = try codec.encode(document)
    guard data.count <= maximumDocumentBytes else {
      throw ExperienceSyncOutboxError.oversizedPersistedDocument(
        actualBytes: data.count,
        maximumBytes: maximumDocumentBytes
      )
    }
    try await storage.save(data)
    cachedDocument = document
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
    guard operationWaiters.isEmpty == false else {
      operationIsActive = false
      return
    }
    operationWaiters.removeFirst().resume()
  }
}
