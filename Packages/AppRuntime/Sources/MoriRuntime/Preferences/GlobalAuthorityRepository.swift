import Foundation
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
  }
}

public enum GlobalAuthorityCodecError: Error, Equatable, Sendable {
  case oversized(actualBytes: Int, maximumBytes: Int)
  case malformed
  case undeclaredField(String)
  case nonCanonical
  case invalidSnapshot
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
    let snapshot: GlobalAuthoritySnapshot
    do {
      snapshot = try codec.decode(GlobalAuthoritySnapshot.self, from: data)
    } catch {
      throw GlobalAuthorityCodecError.malformed
    }
    guard snapshot.isValid else {
      throw GlobalAuthorityCodecError.invalidSnapshot
    }
    let canonical = try codec.encode(snapshot)
    try rejectUndeclaredFields(in: data, canonical: canonical)
    guard data == canonical else {
      throw GlobalAuthorityCodecError.nonCanonical
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

public protocol GlobalAuthorityStorage: Sendable {
  func load() async throws -> Data?
  func save(_ data: Data) async throws
}

public actor InMemoryGlobalAuthorityStorage: GlobalAuthorityStorage {
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

public actor FileGlobalAuthorityStorage: GlobalAuthorityStorage {
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

public actor GlobalAuthorityRepository<Storage: GlobalAuthorityStorage> {
  private let storage: Storage
  private let initialSnapshot: GlobalAuthoritySnapshot
  private let codec: GlobalAuthorityCodec
  private var cached: GlobalAuthoritySnapshot?
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
    return try await loadIfNeeded()
  }

  @discardableResult
  public func merge(
    preferences incoming: GlobalSyncedPreferences
  ) async throws -> GlobalPreferenceMergeResult {
    await acquireOperation()
    defer { releaseOperation() }

    let current = try await loadIfNeeded()
    let result = GlobalPreferenceMerger.merge(
      current: current.preferences,
      incoming: incoming
    )
    guard case .applied(let preferences) = result else { return result }
    let updated = GlobalAuthoritySnapshot(
      preferences: preferences,
      consent: current.consent
    )
    try await persist(updated)
    return result
  }

  @discardableResult
  public func merge(
    consent incoming: GlobalConsentState
  ) async throws -> GlobalConsentMergeResult {
    await acquireOperation()
    defer { releaseOperation() }

    let current = try await loadIfNeeded()
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

  private func loadIfNeeded() async throws -> GlobalAuthoritySnapshot {
    if let cached { return cached }
    let snapshot: GlobalAuthoritySnapshot
    if let data = try await storage.load() {
      snapshot = try codec.decode(data)
    } else {
      snapshot = initialSnapshot
    }
    cached = snapshot
    return snapshot
  }

  private func persist(_ snapshot: GlobalAuthoritySnapshot) async throws {
    let data = try codec.encode(snapshot)
    try await storage.save(data)
    cached = snapshot
  }
}
