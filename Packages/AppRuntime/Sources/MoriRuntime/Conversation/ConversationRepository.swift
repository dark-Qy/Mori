import CryptoKit
import Foundation
import MoriDomain
import MoriPersistence

public struct ConversationPendingTurn: Hashable, Codable, Sendable {
  public let requestID: String
  public let clientTurnID: String
  public let userRecordID: ConversationRecordID
  public let clearGeneration: UInt64

  public init(
    requestID: String,
    clientTurnID: String,
    userRecordID: ConversationRecordID,
    clearGeneration: UInt64
  ) {
    self.requestID = requestID
    self.clientTurnID = clientTurnID
    self.userRecordID = userRecordID
    self.clearGeneration = clearGeneration
  }
}

public struct ConversationCompletedTurn: Hashable, Codable, Sendable {
  public let requestID: String
  public let clientTurnID: String
  public let userRecordID: ConversationRecordID
  public let assistantRecordID: ConversationRecordID
  public let clearGeneration: UInt64

  public init(
    requestID: String,
    clientTurnID: String,
    userRecordID: ConversationRecordID,
    assistantRecordID: ConversationRecordID,
    clearGeneration: UInt64
  ) {
    self.requestID = requestID
    self.clientTurnID = clientTurnID
    self.userRecordID = userRecordID
    self.assistantRecordID = assistantRecordID
    self.clearGeneration = clearGeneration
  }
}

public struct ConversationMemoryContextIndexEntry:
  Hashable, Codable, Sendable
{
  public let memoryID: MemoryID
  public let memoryRevision: LamportRevision

  public init(
    memoryID: MemoryID,
    memoryRevision: LamportRevision
  ) {
    self.memoryID = memoryID
    self.memoryRevision = memoryRevision
  }
}

public struct ConversationRepositoryState: Hashable, Codable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let profile: RuntimeProfile
  public let conversationID: ConversationID
  public var clearGeneration: UInt64
  public var messages: [ConversationRecord]
  public var localSummary: String?
  public var draft: String?
  public var pendingTurns: [ConversationPendingTurn]
  public var completedTurns: [ConversationCompletedTurn]
  public var contextIndex: [ConversationMemoryContextIndexEntry]
  public var nextRevisionCounter: UInt64
  public var lastClearRequestID: String?
  public var firstSendDisclosureVersion: UInt16?

  public init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    profile: RuntimeProfile,
    conversationID: ConversationID = ConversationID("main"),
    clearGeneration: UInt64 = 0,
    messages: [ConversationRecord] = [],
    localSummary: String? = nil,
    draft: String? = nil,
    pendingTurns: [ConversationPendingTurn] = [],
    completedTurns: [ConversationCompletedTurn] = [],
    contextIndex: [ConversationMemoryContextIndexEntry] = [],
    nextRevisionCounter: UInt64 = 0,
    lastClearRequestID: String? = nil,
    firstSendDisclosureVersion: UInt16? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.profile = profile
    self.conversationID = conversationID
    self.clearGeneration = clearGeneration
    self.messages = messages
    self.localSummary = localSummary
    self.draft = draft
    self.pendingTurns = pendingTurns
    self.completedTurns = completedTurns
    self.contextIndex = contextIndex
    self.nextRevisionCounter = nextRevisionCounter
    self.lastClearRequestID = lastClearRequestID
    self.firstSendDisclosureVersion = firstSendDisclosureVersion
  }
}

public enum ConversationRepositoryError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidOriginDeviceID
  case invalidState
  case invalidContent
  case profileMismatch
  case staleClearGeneration
  case staleStorageRevision
  case retiredStorage
  case unknownPendingTurn
  case conflictingTurn
  case malformed
  case nonCanonical
  case oversized(actualBytes: Int, maximumBytes: Int)
}

public enum ConversationStorageRevision: Hashable, Sendable {
  case absent
  case digest(String)

  fileprivate static func current(
    for data: Data?
  ) -> Self {
    guard let data else { return .absent }
    let digest = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    return .digest(digest)
  }
}

public struct ConversationStorageSnapshot: Sendable {
  public let data: Data?
  public let revision: ConversationStorageRevision

  public init(
    data: Data?,
    revision: ConversationStorageRevision
  ) {
    self.data = data
    self.revision = revision
  }
}

public protocol ConversationRepositoryStorage: Sendable {
  func load() async throws -> ConversationStorageSnapshot
  func save(
    _ data: Data,
    replacing expectedRevision: ConversationStorageRevision
  ) async throws -> ConversationStorageRevision
  func remove() async throws
}

public actor InMemoryConversationRepositoryStorage:
  ConversationRepositoryStorage
{
  private var data: Data?
  private var isRetired = false

  public init(data: Data? = nil) {
    self.data = data
  }

  public func load() throws -> ConversationStorageSnapshot {
    guard isRetired == false else {
      throw ConversationRepositoryError.retiredStorage
    }
    return ConversationStorageSnapshot(
      data: data,
      revision: .current(for: data)
    )
  }

  public func save(
    _ data: Data,
    replacing expectedRevision: ConversationStorageRevision
  ) throws -> ConversationStorageRevision {
    guard isRetired == false else {
      throw ConversationRepositoryError.retiredStorage
    }
    guard ConversationStorageRevision.current(for: self.data) == expectedRevision else {
      throw ConversationRepositoryError.staleStorageRevision
    }
    self.data = data
    return .current(for: data)
  }

  public func remove() throws {
    if isRetired { return }
    isRetired = true
    data = nil
  }
}

public actor FileConversationRepositoryStorage:
  ConversationRepositoryStorage
{
  public let fileURL: URL
  let retirementFenceURL: URL
  private let globalRetirementFenceURL: URL?
  private let initialGlobalRetirementRevision: ConversationStorageRevision?

  public init(fileURL: URL) {
    let standardizedFileURL = fileURL.standardizedFileURL
    let locations = Self.retirementLocations(for: standardizedFileURL)
    self.fileURL = standardizedFileURL
    retirementFenceURL = locations.artifact
    globalRetirementFenceURL = locations.global
    initialGlobalRetirementRevision = locations.global.map {
      Self.revisionAtInitialization(for: $0)
    }
  }

  public func load() async throws -> ConversationStorageSnapshot {
    try await ConversationFileCommitCoordinator.shared.load(
      fileURL: fileURL,
      retirementFenceURL: retirementFenceURL,
      globalRetirementFenceURL: globalRetirementFenceURL,
      initialGlobalRetirementRevision: initialGlobalRetirementRevision
    )
  }

  public func save(
    _ data: Data,
    replacing expectedRevision: ConversationStorageRevision
  ) async throws -> ConversationStorageRevision {
    try await ConversationFileCommitCoordinator.shared.save(
      data,
      fileURL: fileURL,
      retirementFenceURL: retirementFenceURL,
      globalRetirementFenceURL: globalRetirementFenceURL,
      initialGlobalRetirementRevision: initialGlobalRetirementRevision,
      replacing: expectedRevision
    )
  }

  public func remove() async throws {
    try await ConversationFileCommitCoordinator.shared.retire(
      fileURL: fileURL,
      retirementFenceURL: retirementFenceURL,
      globalRetirementFenceURL: globalRetirementFenceURL
    )
  }

  private static func retirementLocations(
    for fileURL: URL
  ) -> (artifact: URL, global: URL?) {
    let digest = SHA256.hash(data: Data(fileURL.path.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    var ancestor = fileURL.deletingLastPathComponent()
    while ancestor.pathComponents.count > 1 {
      if ancestor.lastPathComponent == "profiles" {
        let runtimeRoot = ancestor.deletingLastPathComponent()
        return (
          runtimeRoot
            .appendingPathComponent(
              "conversation-retirement-fences-v1",
              isDirectory: true
            )
            .appendingPathComponent("\(digest).fence"),
          runtimeRoot.appendingPathComponent(
            "conversation-global-retirement-v1.fence"
          )
        )
      }
      ancestor.deleteLastPathComponent()
    }
    return (
      fileURL.deletingLastPathComponent()
        .appendingPathComponent(".\(fileURL.lastPathComponent).\(digest).fence"),
      nil
    )
  }

  private static func revisionAtInitialization(
    for fileURL: URL
  ) -> ConversationStorageRevision {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return .absent
    }
    guard let data = try? Data(contentsOf: fileURL) else {
      return .digest("unreadable-global-retirement-fence")
    }
    return .current(for: data)
  }
}

private struct ConversationGlobalRetirementManifest {
  private static let version = "mori-conversation-global-retirement-v1"

  let generation: UUID
  let retiredArtifactIDs: Set<String>

  init?(_ data: Data) {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard
      lines.count >= 3,
      lines[0] == Self.version,
      let generation = UUID(uuidString: String(lines[1])),
      lines.last?.isEmpty == true
    else {
      return nil
    }
    let identifiers = lines.dropFirst(2).dropLast().map(String.init)
    guard
      identifiers.allSatisfy(Self.isArtifactID),
      Set(identifiers).count == identifiers.count,
      identifiers == identifiers.sorted()
    else {
      return nil
    }
    self.generation = generation
    retiredArtifactIDs = Set(identifiers)
  }

  init(retiredArtifactIDs: Set<String>) {
    generation = UUID()
    self.retiredArtifactIDs = retiredArtifactIDs
  }

  func retires(_ fileURL: URL) -> Bool {
    retiredArtifactIDs.contains(Self.artifactID(for: fileURL))
  }

  func encoded() -> Data {
    let identifiers = retiredArtifactIDs.sorted().joined(separator: "\n")
    return Data(
      "\(Self.version)\n\(generation.uuidString)\n\(identifiers)\n".utf8
    )
  }

  static func artifactID(for fileURL: URL) -> String {
    SHA256.hash(data: Data(fileURL.standardizedFileURL.path.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func isArtifactID(_ value: String) -> Bool {
    value.count == 64
      && value.unicodeScalars.allSatisfy {
        ("0"..."9").contains(Character(String($0)))
          || ("a"..."f").contains(Character(String($0)))
      }
  }
}

private actor ConversationFileCommitCoordinator {
  static let shared = ConversationFileCommitCoordinator()

  private let fileManager = FileManager.default

  func load(
    fileURL: URL,
    retirementFenceURL: URL,
    globalRetirementFenceURL: URL?,
    initialGlobalRetirementRevision: ConversationStorageRevision?
  ) throws -> ConversationStorageSnapshot {
    try rejectGloballyRetired(
      fileURL: fileURL,
      globalRetirementFenceURL: globalRetirementFenceURL,
      initialGlobalRetirementRevision: initialGlobalRetirementRevision
    )
    try rejectRetired(retirementFenceURL)
    try ProtectedAtomicFile.removeOrphanedStagingFiles(
      for: fileURL,
      fileManager: fileManager
    )
    let data =
      fileManager.fileExists(atPath: fileURL.path)
      ? try Data(contentsOf: fileURL)
      : nil
    return ConversationStorageSnapshot(
      data: data,
      revision: .current(for: data)
    )
  }

  func save(
    _ data: Data,
    fileURL: URL,
    retirementFenceURL: URL,
    globalRetirementFenceURL: URL?,
    initialGlobalRetirementRevision: ConversationStorageRevision?,
    replacing expectedRevision: ConversationStorageRevision
  ) throws -> ConversationStorageRevision {
    try rejectGloballyRetired(
      fileURL: fileURL,
      globalRetirementFenceURL: globalRetirementFenceURL,
      initialGlobalRetirementRevision: initialGlobalRetirementRevision
    )
    try rejectRetired(retirementFenceURL)
    try ProtectedAtomicFile.removeOrphanedStagingFiles(
      for: fileURL,
      fileManager: fileManager
    )
    let currentData =
      fileManager.fileExists(atPath: fileURL.path)
      ? try Data(contentsOf: fileURL)
      : nil
    guard ConversationStorageRevision.current(for: currentData) == expectedRevision else {
      throw ConversationRepositoryError.staleStorageRevision
    }
    try ProtectedAtomicFile.write(data, to: fileURL)
    return .current(for: data)
  }

  func retire(
    fileURL: URL,
    retirementFenceURL: URL,
    globalRetirementFenceURL: URL?
  ) throws {
    if try isRetired(
      fileURL: fileURL,
      retirementFenceURL: retirementFenceURL,
      globalRetirementFenceURL: globalRetirementFenceURL
    ) {
      try removeArtifact(fileURL)
      return
    }

    if let globalRetirementFenceURL {
      var retiredArtifactIDs = existingRetiredArtifactIDs(
        at: globalRetirementFenceURL
      )
      retiredArtifactIDs.formUnion(
        try existingConversationArtifactIDs(
          globalRetirementFenceURL: globalRetirementFenceURL
        )
      )
      retiredArtifactIDs.insert(
        ConversationGlobalRetirementManifest.artifactID(for: fileURL)
      )
      let manifest = ConversationGlobalRetirementManifest(
        retiredArtifactIDs: retiredArtifactIDs
      )
      try ProtectedAtomicFile.write(
        manifest.encoded(),
        to: globalRetirementFenceURL
      )
    } else {
      let fence = Data("mori-conversation-retired-v1\n".utf8)
      try ProtectedAtomicFile.write(fence, to: retirementFenceURL)
    }

    try removeArtifact(fileURL)
  }

  private func rejectGloballyRetired(
    fileURL: URL,
    globalRetirementFenceURL: URL?,
    initialGlobalRetirementRevision: ConversationStorageRevision?
  ) throws {
    guard
      let globalRetirementFenceURL,
      let initialGlobalRetirementRevision
    else {
      return
    }
    let data =
      fileManager.fileExists(atPath: globalRetirementFenceURL.path)
      ? try Data(contentsOf: globalRetirementFenceURL)
      : nil
    guard
      ConversationStorageRevision.current(for: data)
        == initialGlobalRetirementRevision
    else {
      throw ConversationRepositoryError.retiredStorage
    }
    guard let data else { return }
    guard
      let manifest = ConversationGlobalRetirementManifest(data),
      manifest.retires(fileURL) == false
    else {
      throw ConversationRepositoryError.retiredStorage
    }
  }

  private func isRetired(
    fileURL: URL,
    retirementFenceURL: URL,
    globalRetirementFenceURL: URL?
  ) throws -> Bool {
    if fileManager.fileExists(atPath: retirementFenceURL.path) {
      return true
    }
    guard
      let globalRetirementFenceURL,
      fileManager.fileExists(atPath: globalRetirementFenceURL.path)
    else {
      return false
    }
    let data = try Data(contentsOf: globalRetirementFenceURL)
    guard let manifest = ConversationGlobalRetirementManifest(data) else {
      return true
    }
    return manifest.retires(fileURL)
  }

  private func existingRetiredArtifactIDs(
    at globalRetirementFenceURL: URL
  ) -> Set<String> {
    guard
      fileManager.fileExists(atPath: globalRetirementFenceURL.path),
      let data = try? Data(contentsOf: globalRetirementFenceURL),
      let manifest = ConversationGlobalRetirementManifest(data)
    else {
      return []
    }
    return manifest.retiredArtifactIDs
  }

  private func existingConversationArtifactIDs(
    globalRetirementFenceURL: URL
  ) throws -> Set<String> {
    let profilesURL =
      globalRetirementFenceURL
      .deletingLastPathComponent()
      .appendingPathComponent("profiles", isDirectory: true)
    guard fileManager.fileExists(atPath: profilesURL.path) else {
      return []
    }
    var identifiers: Set<String> = []
    for kind in ["real", "mock"] {
      let kindURL = profilesURL.appendingPathComponent(kind, isDirectory: true)
      guard fileManager.fileExists(atPath: kindURL.path) else { continue }
      for namespaceURL in try fileManager.contentsOfDirectory(
        at: kindURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      ) {
        let values = try namespaceURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { continue }
        let artifactURL =
          namespaceURL
          .appendingPathComponent("conversation", isDirectory: true)
          .appendingPathComponent("conversation.json")
        identifiers.insert(
          ConversationGlobalRetirementManifest.artifactID(for: artifactURL)
        )
      }
    }
    return identifiers
  }

  private func rejectRetired(
    _ retirementFenceURL: URL
  ) throws {
    guard fileManager.fileExists(atPath: retirementFenceURL.path) == false else {
      throw ConversationRepositoryError.retiredStorage
    }
  }

  private func removeArtifact(
    _ fileURL: URL
  ) throws {
    if fileManager.fileExists(atPath: fileURL.path) {
      try fileManager.removeItem(at: fileURL)
    }
    try ProtectedAtomicFile.removeOrphanedStagingFiles(
      for: fileURL,
      fileManager: fileManager
    )
  }
}

public enum ConversationBeginTurnResult: Equatable, Sendable {
  case inserted(ConversationRepositoryState)
  case duplicate(ConversationRepositoryState)
}

public enum ConversationAppendReplyResult: Equatable, Sendable {
  case inserted(ConversationRepositoryState)
  case duplicate(ConversationRepositoryState)
}

public protocol ConversationRepositoryAccessing: Sendable {
  func current() async throws -> ConversationRepositoryState
  func setDraft(_ value: String?) async throws -> ConversationRepositoryState
  func recordFirstSendDisclosure(
    version: UInt16
  ) async throws -> ConversationRepositoryState
  func beginTurn(
    requestID: String,
    clientTurnID: String,
    expectedClearGeneration: UInt64,
    explicitMessage: String,
    at date: Date
  ) async throws -> ConversationBeginTurnResult
  func appendReply(
    requestID: String,
    clientTurnID: String,
    clearGeneration: UInt64,
    content: String,
    referencedMemoryIDs: [MemoryID],
    at date: Date
  ) async throws -> ConversationAppendReplyResult
  func appendLocalFallback(
    requestID: String,
    clientTurnID: String,
    clearGeneration: UInt64,
    content: String,
    at date: Date
  ) async throws -> ConversationRepositoryState
  func retainPendingTurnForRetry(
    requestID: String
  ) async throws -> ConversationRepositoryState
  func abandonPendingTurn(
    requestID: String
  ) async throws -> ConversationRepositoryState
  func replaceContextIndex(
    _ entries: [ConversationMemoryContextIndexEntry],
    expectedClearGeneration: UInt64
  ) async throws -> ConversationRepositoryState
  func revokeMemory(
    _ memoryID: MemoryID
  ) async throws -> ConversationRepositoryState
  func clear(requestID: String) async throws -> ConversationRepositoryState
  func removeAllContent() async throws
}

public actor ConversationRepository<Storage: ConversationRepositoryStorage> {
  private let storage: Storage
  private let profile: RuntimeProfile
  private let originDeviceID: String
  private let configuration: ConversationRuntimeConfiguration
  private let codec = CanonicalJSONCodec()
  private var cached: ConversationRepositoryState?
  private var storageRevision: ConversationStorageRevision?
  private var hasRemovedAllContent = false

  public init(
    storage: Storage,
    profile: RuntimeProfile,
    originDeviceID: String,
    configuration: ConversationRuntimeConfiguration = .standard
  ) throws {
    let normalizedOrigin = originDeviceID.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard configuration.isValid else {
      throw ConversationRepositoryError.invalidConfiguration
    }
    guard normalizedOrigin.isEmpty == false else {
      throw ConversationRepositoryError.invalidOriginDeviceID
    }
    guard profile.isValid else {
      throw ConversationRepositoryError.invalidState
    }
    self.storage = storage
    self.profile = profile
    self.originDeviceID = normalizedOrigin
    self.configuration = configuration
  }

  public func current() async throws -> ConversationRepositoryState {
    try await loadIfNeeded()
  }

  @discardableResult
  public func setDraft(
    _ value: String?
  ) async throws -> ConversationRepositoryState {
    var state = try await loadIfNeeded(rejectChangedCachedRevision: true)
    if let value {
      guard value.unicodeScalars.count <= configuration.maximumMessageScalars else {
        throw ConversationRepositoryError.invalidContent
      }
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      state.draft = normalized.isEmpty ? nil : value
    } else {
      state.draft = nil
    }
    try await persist(state)
    return state
  }

  @discardableResult
  public func recordFirstSendDisclosure(
    version: UInt16
  ) async throws -> ConversationRepositoryState {
    guard version > 0 else {
      throw ConversationRepositoryError.invalidContent
    }
    var state = try await loadIfNeeded(rejectChangedCachedRevision: true)
    state.firstSendDisclosureVersion = max(
      state.firstSendDisclosureVersion ?? 0,
      version
    )
    try await persist(state)
    return state
  }

  public func beginTurn(
    requestID: String,
    clientTurnID: String,
    expectedClearGeneration: UInt64,
    explicitMessage: String,
    at date: Date
  ) async throws -> ConversationBeginTurnResult {
    let normalizedRequest = requestID.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let normalizedTurn = clientTurnID.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let normalizedMessage = explicitMessage.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard
      normalizedRequest.isEmpty == false,
      normalizedTurn.isEmpty == false,
      normalizedRequest.unicodeScalars.count <= 128,
      normalizedTurn.unicodeScalars.count <= 128,
      normalizedMessage.isEmpty == false,
      explicitMessage.unicodeScalars.count <= configuration.maximumMessageScalars
    else {
      throw ConversationRepositoryError.invalidContent
    }

    var state = try await loadIfNeeded(rejectChangedCachedRevision: true)
    guard state.clearGeneration == expectedClearGeneration else {
      throw ConversationRepositoryError.staleClearGeneration
    }
    if let completed = state.completedTurns.first(where: {
      $0.clientTurnID == normalizedTurn
    }) {
      guard completed.requestID == normalizedRequest else {
        throw ConversationRepositoryError.conflictingTurn
      }
      return .duplicate(state)
    }
    if let pending = state.pendingTurns.first(where: {
      $0.clientTurnID == normalizedTurn
    }) {
      guard pending.requestID == normalizedRequest else {
        throw ConversationRepositoryError.conflictingTurn
      }
      return .duplicate(state)
    }

    let revision = nextRevision(in: &state)
    let recordID = ConversationRecordID("turn-\(normalizedTurn)-user")
    let record = ConversationRecord(
      header: header(recordID),
      conversationID: state.conversationID,
      role: .user,
      content: explicitMessage,
      localTime: date,
      referencedMemoryIDs: [],
      revision: revision
    )
    guard record.validate(in: profile) == nil else {
      throw ConversationRepositoryError.invalidContent
    }
    state.messages.append(record)
    state.pendingTurns.append(
      ConversationPendingTurn(
        requestID: normalizedRequest,
        clientTurnID: normalizedTurn,
        userRecordID: recordID,
        clearGeneration: state.clearGeneration
      )
    )
    state.draft = nil
    trimMessages(in: &state)
    try await persist(state)
    return .inserted(state)
  }

  public func appendReply(
    requestID: String,
    clientTurnID: String,
    clearGeneration: UInt64,
    content: String,
    referencedMemoryIDs: [MemoryID],
    at date: Date
  ) async throws -> ConversationAppendReplyResult {
    let normalizedContent = content.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard
      requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      clientTurnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      requestID.unicodeScalars.count <= 128,
      clientTurnID.unicodeScalars.count <= 128,
      normalizedContent.isEmpty == false,
      content.unicodeScalars.count <= configuration.maximumReplyScalars,
      referencedMemoryIDs.allSatisfy(\.isValid)
    else {
      throw ConversationRepositoryError.invalidContent
    }

    var state = try await loadIfNeeded(rejectChangedCachedRevision: true)
    guard state.clearGeneration == clearGeneration else {
      throw ConversationRepositoryError.staleClearGeneration
    }
    if let completed = state.completedTurns.first(where: {
      $0.clientTurnID == clientTurnID
    }) {
      guard completed.requestID == requestID else {
        throw ConversationRepositoryError.conflictingTurn
      }
      return .duplicate(state)
    }
    guard
      let pendingIndex = state.pendingTurns.firstIndex(where: {
        $0.requestID == requestID
          && $0.clientTurnID == clientTurnID
          && $0.clearGeneration == clearGeneration
      })
    else {
      throw ConversationRepositoryError.unknownPendingTurn
    }
    let pending = state.pendingTurns[pendingIndex]
    let revision = nextRevision(in: &state)
    let assistantID = ConversationRecordID("turn-\(clientTurnID)-mori")
    let record = ConversationRecord(
      header: header(assistantID),
      conversationID: state.conversationID,
      role: .mori,
      content: content,
      localTime: date,
      referencedMemoryIDs: Array(Set(referencedMemoryIDs)).sorted(),
      revision: revision
    )
    guard record.validate(in: profile) == nil else {
      throw ConversationRepositoryError.invalidContent
    }
    state.messages.append(record)
    state.pendingTurns.remove(at: pendingIndex)
    state.completedTurns.append(
      ConversationCompletedTurn(
        requestID: requestID,
        clientTurnID: clientTurnID,
        userRecordID: pending.userRecordID,
        assistantRecordID: assistantID,
        clearGeneration: clearGeneration
      )
    )
    state.completedTurns = Array(
      state.completedTurns.suffix(configuration.maximumStoredMessages / 2)
    )
    state.localSummary = Self.redactedLocalSummary(
      from: state.messages,
      maximumScalars: 240
    )
    trimMessages(in: &state)
    try await persist(state)
    return .inserted(state)
  }

  @discardableResult
  public func appendLocalFallback(
    requestID: String,
    clientTurnID: String,
    clearGeneration: UInt64,
    content: String,
    at date: Date
  ) async throws -> ConversationRepositoryState {
    let normalizedContent = content.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard
      normalizedContent.isEmpty == false,
      content.unicodeScalars.count <= configuration.maximumReplyScalars
    else {
      throw ConversationRepositoryError.invalidContent
    }
    var state = try await loadIfNeeded(rejectChangedCachedRevision: true)
    guard state.clearGeneration == clearGeneration else {
      throw ConversationRepositoryError.staleClearGeneration
    }
    guard
      state.pendingTurns.contains(where: {
        $0.requestID == requestID
          && $0.clientTurnID == clientTurnID
          && $0.clearGeneration == clearGeneration
      })
    else {
      throw ConversationRepositoryError.unknownPendingTurn
    }
    let recordID = ConversationRecordID(
      "turn-\(clientTurnID)-local-\(requestID)"
    )
    if state.messages.contains(where: { $0.header.recordID == recordID }) {
      return state
    }
    let revision = nextRevision(in: &state)
    let record = ConversationRecord(
      header: header(recordID),
      conversationID: state.conversationID,
      role: .localSystem,
      content: content,
      localTime: date,
      referencedMemoryIDs: [],
      revision: revision
    )
    guard record.validate(in: profile) == nil else {
      throw ConversationRepositoryError.invalidContent
    }
    state.messages.append(record)
    trimMessages(in: &state)
    try await persist(state)
    return state
  }

  @discardableResult
  public func retainPendingTurnForRetry(
    requestID: String
  ) async throws -> ConversationRepositoryState {
    let state = try await loadIfNeeded()
    guard state.pendingTurns.contains(where: { $0.requestID == requestID }) else {
      throw ConversationRepositoryError.unknownPendingTurn
    }
    return state
  }

  @discardableResult
  public func abandonPendingTurn(
    requestID: String
  ) async throws -> ConversationRepositoryState {
    var state = try await loadIfNeeded(rejectChangedCachedRevision: true)
    state.pendingTurns.removeAll { $0.requestID == requestID }
    try await persist(state)
    return state
  }

  @discardableResult
  public func replaceContextIndex(
    _ entries: [ConversationMemoryContextIndexEntry],
    expectedClearGeneration: UInt64
  ) async throws -> ConversationRepositoryState {
    guard
      entries.count <= 16,
      entries.allSatisfy({
        $0.memoryID.isValid && $0.memoryRevision.isValid
      }),
      Set(entries.map(\.memoryID)).count == entries.count
    else {
      throw ConversationRepositoryError.invalidContent
    }
    var state = try await loadIfNeeded(rejectChangedCachedRevision: true)
    guard state.clearGeneration == expectedClearGeneration else {
      throw ConversationRepositoryError.staleClearGeneration
    }
    state.contextIndex = entries.sorted { $0.memoryID < $1.memoryID }
    try await persist(state)
    return state
  }

  @discardableResult
  public func revokeMemory(
    _ memoryID: MemoryID
  ) async throws -> ConversationRepositoryState {
    var state = try await loadIfNeeded(rejectChangedCachedRevision: true)
    state.contextIndex.removeAll { $0.memoryID == memoryID }
    try await persist(state)
    return state
  }

  @discardableResult
  public func clear(
    requestID: String
  ) async throws -> ConversationRepositoryState {
    let normalizedRequest = requestID.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard
      normalizedRequest.isEmpty == false,
      normalizedRequest.unicodeScalars.count <= 128
    else {
      throw ConversationRepositoryError.invalidContent
    }
    var state = try await loadIfNeeded(rejectChangedCachedRevision: true)
    if state.lastClearRequestID == normalizedRequest {
      return state
    }
    guard state.clearGeneration < UInt64.max else {
      throw ConversationRepositoryError.invalidState
    }
    state.clearGeneration += 1
    state.messages = []
    state.localSummary = nil
    state.draft = nil
    state.pendingTurns = []
    state.completedTurns = []
    state.contextIndex = []
    state.lastClearRequestID = normalizedRequest
    try await persist(state)
    return state
  }

  public func removeAllContent() async throws {
    if hasRemovedAllContent { return }
    cached = nil
    self.storageRevision = nil
    try await storage.remove()
    hasRemovedAllContent = true
  }

  private func loadIfNeeded(
    rejectChangedCachedRevision: Bool = false
  ) async throws -> ConversationRepositoryState {
    let snapshot = try await storage.load()
    if let cached,
      snapshot.revision == storageRevision
    {
      return cached
    }
    if rejectChangedCachedRevision, cached != nil {
      cached = nil
      storageRevision = nil
      throw ConversationRepositoryError.staleStorageRevision
    }
    let state: ConversationRepositoryState
    storageRevision = snapshot.revision
    if let data = snapshot.data {
      guard data.count <= configuration.maximumStoredBytes else {
        throw ConversationRepositoryError.oversized(
          actualBytes: data.count,
          maximumBytes: configuration.maximumStoredBytes
        )
      }
      do {
        state = try codec.decode(
          ConversationRepositoryState.self,
          from: data
        )
      } catch {
        throw ConversationRepositoryError.malformed
      }
      let canonical: Data
      do {
        canonical = try codec.encode(state)
      } catch {
        throw ConversationRepositoryError.malformed
      }
      guard canonical == data else {
        throw ConversationRepositoryError.nonCanonical
      }
    } else {
      state = ConversationRepositoryState(profile: profile)
    }
    try validate(state)
    cached = state
    return state
  }

  private func persist(
    _ state: ConversationRepositoryState
  ) async throws {
    try validate(state)
    let data: Data
    do {
      data = try codec.encode(state)
    } catch {
      throw ConversationRepositoryError.invalidState
    }
    guard data.count <= configuration.maximumStoredBytes else {
      throw ConversationRepositoryError.oversized(
        actualBytes: data.count,
        maximumBytes: configuration.maximumStoredBytes
      )
    }
    guard let storageRevision else {
      throw ConversationRepositoryError.invalidState
    }
    do {
      self.storageRevision = try await storage.save(
        data,
        replacing: storageRevision
      )
      cached = state
    } catch {
      cached = nil
      self.storageRevision = nil
      throw error
    }
  }

  private func validate(
    _ state: ConversationRepositoryState
  ) throws {
    guard
      state.schemaVersion == ConversationRepositoryState.currentSchemaVersion,
      state.profile == profile,
      state.conversationID.isValid,
      state.messages.count <= configuration.maximumStoredMessages,
      state.messages.allSatisfy({
        $0.conversationID == state.conversationID
          && $0.validate(in: profile) == nil
          && $0.content.unicodeScalars.count <= configuration.maximumMessageScalars
      }),
      state.draft?.unicodeScalars.count ?? 0
        <= configuration.maximumMessageScalars,
      state.localSummary?.unicodeScalars.count ?? 0 <= 240,
      Set(state.messages.map(\.header.recordID)).count == state.messages.count,
      Set(state.pendingTurns.map(\.requestID)).count
        == state.pendingTurns.count,
      Set(state.pendingTurns.map(\.clientTurnID)).count
        == state.pendingTurns.count,
      Set(state.completedTurns.map(\.requestID)).count
        == state.completedTurns.count,
      Set(state.completedTurns.map(\.clientTurnID)).count
        == state.completedTurns.count,
      Set(state.contextIndex.map(\.memoryID)).count
        == state.contextIndex.count,
      state.pendingTurns.allSatisfy({ turn in
        turn.clearGeneration == state.clearGeneration
          && state.messages.contains(where: { message in
            message.header.recordID == turn.userRecordID
              && message.role == .user
          })
      }),
      state.completedTurns.allSatisfy({ turn in
        turn.clearGeneration == state.clearGeneration
          && state.messages.contains(where: { message in
            message.header.recordID == turn.userRecordID
              && message.role == .user
          })
          && state.messages.contains(where: { message in
            message.header.recordID == turn.assistantRecordID
              && message.role == .mori
          })
      })
    else {
      throw ConversationRepositoryError.invalidState
    }

    let revisions = state.messages.map(\.revision)
    guard revisions == revisions.sorted() else {
      throw ConversationRepositoryError.invalidState
    }
    let maximumCounter = revisions.map(\.counter).max() ?? 0
    guard state.nextRevisionCounter >= maximumCounter else {
      throw ConversationRepositoryError.invalidState
    }
  }

  private func nextRevision(
    in state: inout ConversationRepositoryState
  ) -> LamportRevision {
    state.nextRevisionCounter &+= 1
    return LamportRevision(
      counter: state.nextRevisionCounter,
      originDeviceID: originDeviceID
    )
  }

  private func header(
    _ recordID: ConversationRecordID
  ) -> ProfileScopedRecordHeader<ConversationRecordID> {
    ProfileScopedRecordHeader(
      recordID: recordID,
      profileID: profile.id,
      profileEpoch: profile.epoch,
      deletionEpoch: profile.deletionEpoch
    )
  }

  private func trimMessages(
    in state: inout ConversationRepositoryState
  ) {
    guard state.messages.count > configuration.maximumStoredMessages else {
      return
    }
    let protectedIDs = Set(
      state.pendingTurns.map(\.userRecordID)
    )
    while state.messages.count > configuration.maximumStoredMessages {
      guard
        let removable = state.messages.firstIndex(where: {
          protectedIDs.contains($0.header.recordID) == false
        })
      else {
        break
      }
      state.messages.remove(at: removable)
    }
    let retainedIDs = Set(state.messages.map(\.header.recordID))
    state.completedTurns.removeAll {
      retainedIDs.contains($0.userRecordID) == false
        || retainedIDs.contains($0.assistantRecordID) == false
    }
  }

  private static func redactedLocalSummary(
    from messages: [ConversationRecord],
    maximumScalars: Int
  ) -> String? {
    let roles = messages.suffix(8).map { message in
      switch message.role {
      case .user: "user"
      case .mori: "mori"
      case .localSystem: "local"
      }
    }
    guard roles.isEmpty == false else { return nil }
    return String(
      "recent roles: \(roles.joined(separator: ","))"
        .unicodeScalars
        .prefix(maximumScalars)
    )
  }
}

extension ConversationRepository: ConversationRepositoryAccessing {}
