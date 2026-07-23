import Foundation

protocol ManagementSyncOutboxStorage: Sendable {
  func load() async throws -> Data?
  func save(_ data: Data) async throws
}

actor InMemoryManagementSyncOutboxStorage: ManagementSyncOutboxStorage {
  private var data: Data?

  init(data: Data? = nil) {
    self.data = data
  }

  func load() -> Data? { data }
  func save(_ data: Data) { self.data = data }
}

actor FileManagementSyncOutboxStorage: ManagementSyncOutboxStorage {
  let fileURL: URL

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  func load() throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try Data(contentsOf: fileURL)
  }

  func save(_ data: Data) throws {
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

struct ManagementSyncOperation: Codable, Equatable, Sendable {
  let operationID: UUID
  let revision: UInt64
  let updatedAt: Date
  let values: [String: String]
}

private struct ManagementSyncOutboxDocument: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion = currentSchemaVersion
  var lastRevision: UInt64 = 0
  var pending: ManagementSyncOperation?
}

enum ManagementSyncOutboxError: Error, Equatable, Sendable {
  case unsupportedSchema(Int)
  case revisionExhausted
}

/// Durable, latest-value outbox for iPhone-owned management state.
///
/// A newer operation replaces an older pending operation because WatchConnectivity application
/// context also has latest-value semantics. The persisted `lastRevision` remains after an
/// acknowledgement, preserving monotonic revisions across relaunch and clock rollback.
actor ManagementSyncOutbox<Storage: ManagementSyncOutboxStorage> {
  private let storage: Storage
  private var cachedDocument: ManagementSyncOutboxDocument?

  init(storage: Storage) {
    self.storage = storage
  }

  @discardableResult
  func enqueue(
    values: [String: String],
    updatedAt: Date,
    operationID: UUID = UUID()
  ) async throws -> ManagementSyncOperation {
    var document = try await loadDocument()
    if let pending = document.pending, pending.values == values {
      return pending
    }
    guard document.lastRevision < UInt64.max else {
      throw ManagementSyncOutboxError.revisionExhausted
    }
    let clockRevision = UInt64(max(0, updatedAt.timeIntervalSince1970 * 1_000))
    let revision = max(document.lastRevision + 1, clockRevision)
    let operation = ManagementSyncOperation(
      operationID: operationID,
      revision: revision,
      updatedAt: updatedAt,
      values: values
    )
    document.lastRevision = revision
    document.pending = operation
    try await persist(document)
    return operation
  }

  func pendingOperation() async throws -> ManagementSyncOperation? {
    try await loadDocument().pending
  }

  func acknowledge(revision: UInt64) async throws {
    var document = try await loadDocument()
    guard let pending = document.pending, pending.revision <= revision else { return }
    document.pending = nil
    try await persist(document)
  }

  private func loadDocument() async throws -> ManagementSyncOutboxDocument {
    if let cachedDocument { return cachedDocument }
    guard let data = try await storage.load() else {
      let empty = ManagementSyncOutboxDocument()
      cachedDocument = empty
      return empty
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let document = try decoder.decode(ManagementSyncOutboxDocument.self, from: data)
    guard document.schemaVersion == ManagementSyncOutboxDocument.currentSchemaVersion else {
      throw ManagementSyncOutboxError.unsupportedSchema(document.schemaVersion)
    }
    cachedDocument = document
    return document
  }

  private func persist(_ document: ManagementSyncOutboxDocument) async throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    try await storage.save(encoder.encode(document))
    cachedDocument = document
  }
}
