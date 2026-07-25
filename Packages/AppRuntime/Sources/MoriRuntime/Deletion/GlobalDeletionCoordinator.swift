import CryptoKit
import Foundation
import MoriDomain
import MoriPersistence

public enum GlobalDeletionPhase: String, Hashable, Codable, Sendable {
  case requested
  case deletionFencePrepared
  case localContentCleared
  case peersPending
  case processorsPending
  case acknowledged
}

public enum GlobalDeletionParticipantKind: String, Hashable, Codable, Sendable {
  case peer
  case processor
}

public enum GlobalDeletionParticipantStatus: String, Hashable, Codable, Sendable {
  case pending
  case acknowledged
  case notApplicable
}

public struct GlobalDeletionParticipant: Hashable, Codable, Sendable {
  public let kind: GlobalDeletionParticipantKind
  public let identifier: String
  public let status: GlobalDeletionParticipantStatus
  public let acknowledgedAt: Date?

  public init(
    kind: GlobalDeletionParticipantKind,
    identifier: String,
    status: GlobalDeletionParticipantStatus,
    acknowledgedAt: Date? = nil
  ) {
    self.kind = kind
    self.identifier = identifier
    self.status = status
    self.acknowledgedAt = acknowledgedAt
  }

  fileprivate var isValid: Bool {
    let normalized = identifier.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    return
      normalized == identifier
      && normalized.isEmpty == false
      && normalized.unicodeScalars.count <= 128
      && (status == .acknowledged) == (acknowledgedAt != nil)
      && (acknowledgedAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
  }
}

/// A content-free reference to a processor-owned deletion retry capability.
///
/// Provider credentials and user content never belong in this store. A future
/// production adapter may resolve this identifier through a separate,
/// deletion-only credential boundary.
public struct GlobalDeletionRetryTicket: Hashable, Codable, Sendable {
  public let processorID: String
  public let opaqueTicketID: String
  public let expiresAt: Date
  public let acknowledgedAt: Date?

  public init(
    processorID: String,
    opaqueTicketID: String,
    expiresAt: Date,
    acknowledgedAt: Date? = nil
  ) {
    self.processorID = processorID
    self.opaqueTicketID = opaqueTicketID
    self.expiresAt = expiresAt
    self.acknowledgedAt = acknowledgedAt
  }

  fileprivate var isValid: Bool {
    let processor = processorID.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let ticket = opaqueTicketID.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    return
      processor == processorID
      && processor.isEmpty == false
      && processor.unicodeScalars.count <= 128
      && ticket == opaqueTicketID
      && ticket.isEmpty == false
      && ticket.unicodeScalars.count <= 256
      && expiresAt.timeIntervalSinceReferenceDate.isFinite
      && (acknowledgedAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
  }

  fileprivate var isAcknowledged: Bool {
    acknowledgedAt != nil
  }

  private enum CodingKeys: String, CodingKey {
    case processorID
    case opaqueTicketID
    case expiresAt
    case acknowledgedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    processorID = try container.decode(String.self, forKey: .processorID)
    opaqueTicketID = try container.decode(String.self, forKey: .opaqueTicketID)
    expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    acknowledgedAt = try container.decodeIfPresent(
      Date.self,
      forKey: .acknowledgedAt
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(processorID, forKey: .processorID)
    try container.encode(opaqueTicketID, forKey: .opaqueTicketID)
    try container.encode(expiresAt, forKey: .expiresAt)
    try container.encodeIfPresent(
      acknowledgedAt,
      forKey: .acknowledgedAt
    )
  }
}

public struct GlobalDeletionTransaction: Hashable, Codable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let deletionEpoch: DeletionEpoch
  public let phase: GlobalDeletionPhase
  public let createdAt: Date
  public let updatedAt: Date
  public let retainUntil: Date
  public let participants: [GlobalDeletionParticipant]
  public let retryTickets: [GlobalDeletionRetryTicket]

  public init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    deletionEpoch: DeletionEpoch,
    phase: GlobalDeletionPhase,
    createdAt: Date,
    updatedAt: Date,
    retainUntil: Date,
    participants: [GlobalDeletionParticipant],
    retryTickets: [GlobalDeletionRetryTicket]
  ) {
    self.schemaVersion = schemaVersion
    self.deletionEpoch = deletionEpoch
    self.phase = phase
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.retainUntil = retainUntil
    self.participants = participants
    self.retryTickets = retryTickets
  }

  public var pendingPeerIDs: [String] {
    participants.compactMap {
      $0.kind == .peer && $0.status == .pending ? $0.identifier : nil
    }
  }

  public var pendingProcessorIDs: [String] {
    participants.compactMap {
      $0.kind == .processor && $0.status == .pending ? $0.identifier : nil
    }
  }

  public var isAcknowledged: Bool {
    phase == .acknowledged
  }

  fileprivate var isValid: Bool {
    guard
      schemaVersion == Self.currentSchemaVersion,
      deletionEpoch.isValid,
      createdAt.timeIntervalSinceReferenceDate.isFinite,
      updatedAt.timeIntervalSinceReferenceDate.isFinite,
      retainUntil.timeIntervalSinceReferenceDate.isFinite,
      createdAt <= updatedAt,
      updatedAt <= retainUntil,
      participants.allSatisfy(\.isValid),
      retryTickets.allSatisfy(\.isValid)
    else {
      return false
    }
    let participantKeys = participants.map {
      "\($0.kind.rawValue):\($0.identifier)"
    }
    guard
      Set(participantKeys).count == participantKeys.count,
      participants == participants.sorted(by: Self.participantOrder),
      Set(retryTickets.map(Self.retryTicketIdentity)).count
        == retryTickets.count,
      retryTickets == retryTickets.sorted(by: Self.retryTicketOrder),
      retryTickets.allSatisfy({
        createdAt <= $0.expiresAt && $0.expiresAt <= retainUntil
      }),
      retryTickets.allSatisfy({
        guard let acknowledgedAt = $0.acknowledgedAt else { return true }
        return createdAt <= acknowledgedAt && acknowledgedAt <= retainUntil
      }),
      retryTickets.allSatisfy({ ticket in
        participants.contains {
          $0.kind == .processor && $0.identifier == ticket.processorID
        }
      }),
      participants.allSatisfy({ participant in
        guard participant.kind == .processor else { return true }
        let tickets = retryTickets.filter {
          $0.processorID == participant.identifier
        }
        guard tickets.isEmpty == false else { return true }
        let allTicketsAcknowledged = tickets.allSatisfy(\.isAcknowledged)
        switch participant.status {
        case .pending:
          return allTicketsAcknowledged == false
        case .acknowledged:
          return allTicketsAcknowledged
        case .notApplicable:
          return false
        }
      })
    else {
      return false
    }
    switch phase {
    case .requested, .deletionFencePrepared, .localContentCleared:
      return participants.contains(where: { $0.status == .acknowledged }) == false
    case .peersPending:
      return pendingPeerIDs.isEmpty == false
    case .processorsPending:
      return pendingPeerIDs.isEmpty && pendingProcessorIDs.isEmpty == false
    case .acknowledged:
      return pendingPeerIDs.isEmpty && pendingProcessorIDs.isEmpty
    }
  }

  fileprivate static func participantOrder(
    _ lhs: GlobalDeletionParticipant,
    _ rhs: GlobalDeletionParticipant
  ) -> Bool {
    if lhs.kind.rawValue != rhs.kind.rawValue {
      return lhs.kind.rawValue < rhs.kind.rawValue
    }
    return lhs.identifier < rhs.identifier
  }

  fileprivate static func retryTicketOrder(
    _ lhs: GlobalDeletionRetryTicket,
    _ rhs: GlobalDeletionRetryTicket
  ) -> Bool {
    if lhs.processorID != rhs.processorID {
      return lhs.processorID < rhs.processorID
    }
    if lhs.opaqueTicketID != rhs.opaqueTicketID {
      return lhs.opaqueTicketID < rhs.opaqueTicketID
    }
    return lhs.expiresAt < rhs.expiresAt
  }

  fileprivate static func retryTicketIdentity(
    _ ticket: GlobalDeletionRetryTicket
  ) -> String {
    "\(ticket.processorID.unicodeScalars.count):\(ticket.processorID)"
      + "\(ticket.opaqueTicketID.unicodeScalars.count):\(ticket.opaqueTicketID)"
  }
}

public enum GlobalDeletionCoordinatorError: Error, Equatable, Sendable {
  case invalidTransaction
  case invalidParticipant
  case staleDeletionEpoch
  case fenceNotPrepared
  case localContentNotCleared
  case unknownParticipant
  case retryTicketRequired(processorID: String)
  case unexpectedRetryTicket(kind: GlobalDeletionParticipantKind)
  case unknownRetryTicket(
    processorID: String,
    opaqueTicketID: String
  )
  case conflictingRetryTicket(
    processorID: String,
    opaqueTicketID: String
  )
  case staleStorageRevision
  case oversized(actualBytes: Int, maximumBytes: Int)
  case malformed
  case undeclaredField(String)
  case nonCanonical
}

public enum DeletionFenceStorageRevision: Hashable, Sendable {
  case absent
  case digest(String)

  fileprivate static func current(for data: Data?) -> Self {
    guard let data else { return .absent }
    return .digest(
      SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    )
  }
}

public struct DeletionFenceStorageSnapshot: Sendable {
  public let data: Data?
  public let revision: DeletionFenceStorageRevision

  public init(
    data: Data?,
    revision: DeletionFenceStorageRevision
  ) {
    self.data = data
    self.revision = revision
  }
}

public protocol DeletionFenceStorage: Sendable {
  func load() async throws -> DeletionFenceStorageSnapshot
  func save(
    _ data: Data,
    replacing expectedRevision: DeletionFenceStorageRevision
  ) async throws -> DeletionFenceStorageRevision
}

public actor InMemoryDeletionFenceStorage: DeletionFenceStorage {
  private var data: Data?

  public init(data: Data? = nil) {
    self.data = data
  }

  public func load() -> DeletionFenceStorageSnapshot {
    DeletionFenceStorageSnapshot(
      data: data,
      revision: .current(for: data)
    )
  }

  public func save(
    _ data: Data,
    replacing expectedRevision: DeletionFenceStorageRevision
  ) throws -> DeletionFenceStorageRevision {
    guard DeletionFenceStorageRevision.current(for: self.data) == expectedRevision
    else {
      throw GlobalDeletionCoordinatorError.staleStorageRevision
    }
    self.data = data
    return .current(for: data)
  }
}

public actor FileDeletionFenceStorage: DeletionFenceStorage {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL.standardizedFileURL
  }

  public func load() async throws -> DeletionFenceStorageSnapshot {
    try await DeletionFenceFileCommitCoordinator.shared.load(fileURL)
  }

  public func save(
    _ data: Data,
    replacing expectedRevision: DeletionFenceStorageRevision
  ) async throws -> DeletionFenceStorageRevision {
    try await DeletionFenceFileCommitCoordinator.shared.save(
      data,
      to: fileURL,
      replacing: expectedRevision
    )
  }
}

private actor DeletionFenceFileCommitCoordinator {
  static let shared = DeletionFenceFileCommitCoordinator()

  func load(_ fileURL: URL) throws -> DeletionFenceStorageSnapshot {
    try ProtectedAtomicFile.removeOrphanedStagingFiles(for: fileURL)
    let data =
      FileManager.default.fileExists(atPath: fileURL.path)
      ? try Data(contentsOf: fileURL)
      : nil
    return DeletionFenceStorageSnapshot(
      data: data,
      revision: .current(for: data)
    )
  }

  func save(
    _ data: Data,
    to fileURL: URL,
    replacing expectedRevision: DeletionFenceStorageRevision
  ) throws -> DeletionFenceStorageRevision {
    let current =
      FileManager.default.fileExists(atPath: fileURL.path)
      ? try Data(contentsOf: fileURL)
      : nil
    guard DeletionFenceStorageRevision.current(for: current) == expectedRevision
    else {
      throw GlobalDeletionCoordinatorError.staleStorageRevision
    }
    try ProtectedAtomicFile.write(data, to: fileURL)
    return .current(for: data)
  }
}

public struct GlobalDeletionTransactionCodec: Sendable {
  public static let defaultMaximumBytes = 64 * 1_024

  private let maximumBytes: Int
  private let codec: CanonicalJSONCodec

  public init(
    maximumBytes: Int = Self.defaultMaximumBytes,
    codec: CanonicalJSONCodec = CanonicalJSONCodec()
  ) {
    self.maximumBytes = max(1, maximumBytes)
    self.codec = codec
  }

  public func encode(_ transaction: GlobalDeletionTransaction) throws -> Data {
    guard transaction.isValid else {
      throw GlobalDeletionCoordinatorError.invalidTransaction
    }
    let data = try codec.encode(transaction)
    try validateSize(data)
    return data
  }

  public func decode(_ data: Data) throws -> GlobalDeletionTransaction {
    try validateSize(data)
    let transaction: GlobalDeletionTransaction
    do {
      transaction = try codec.decode(
        GlobalDeletionTransaction.self,
        from: data
      )
    } catch {
      throw GlobalDeletionCoordinatorError.malformed
    }
    guard transaction.isValid else {
      throw GlobalDeletionCoordinatorError.invalidTransaction
    }
    let canonical = try codec.encode(transaction)
    try rejectUndeclaredFields(in: data, canonical: canonical)
    guard data == canonical else {
      throw GlobalDeletionCoordinatorError.nonCanonical
    }
    return transaction
  }

  private func validateSize(_ data: Data) throws {
    guard data.count <= maximumBytes else {
      throw GlobalDeletionCoordinatorError.oversized(
        actualBytes: data.count,
        maximumBytes: maximumBytes
      )
    }
  }

  private func rejectUndeclaredFields(
    in sourceData: Data,
    canonical canonicalData: Data
  ) throws {
    let source: Any
    let canonical: Any
    do {
      source = try JSONSerialization.jsonObject(with: sourceData)
      canonical = try JSONSerialization.jsonObject(with: canonicalData)
    } catch {
      throw GlobalDeletionCoordinatorError.malformed
    }
    if let field = firstUndeclaredField(
      in: source,
      comparedTo: canonical,
      path: "$"
    ) {
      throw GlobalDeletionCoordinatorError.undeclaredField(field)
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
      guard let canonical = canonical as? [Any], source.count == canonical.count
      else {
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

public enum FreshInstallDeletionDecision: Hashable, Sendable {
  case accept(deletionEpoch: DeletionEpoch)
  case rejectStaleContent(highestKnown: DeletionEpoch)
  case requiresRecovery(highestKnown: DeletionEpoch)
}

/// Owns only the content-free global deletion transaction.
///
/// Product content is cleared by registered participants after `prepareFence`
/// succeeds. This actor never stores message, health, location, memory, task,
/// collection, social-card, or notification payload content.
public actor GlobalDeletionCoordinator<Storage: DeletionFenceStorage> {
  private static var maximumCASAttempts: Int { 8 }

  private let storage: Storage
  private let codec: GlobalDeletionTransactionCodec
  private var mutationIsActive = false
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    storage: Storage,
    codec: GlobalDeletionTransactionCodec = GlobalDeletionTransactionCodec()
  ) {
    self.storage = storage
    self.codec = codec
  }

  public func current() async throws -> GlobalDeletionTransaction? {
    let snapshot = try await storage.load()
    return try snapshot.data.map(codec.decode)
  }

  @discardableResult
  public func request(
    deletionEpoch: DeletionEpoch,
    peerIDs: [String],
    processorIDs: [String],
    retryTickets: [GlobalDeletionRetryTicket] = [],
    at date: Date,
    retainUntil: Date
  ) async throws -> GlobalDeletionTransaction {
    await acquireMutation()
    defer { releaseMutation() }
    guard
      deletionEpoch.isValid,
      date <= retainUntil,
      retryTickets.contains(where: \.isAcknowledged) == false
    else {
      throw GlobalDeletionCoordinatorError.invalidTransaction
    }
    let peers = try participants(
      kind: .peer,
      identifiers: peerIDs
    )
    let processors = try participants(
      kind: .processor,
      identifiers: processorIDs
    )
    let transaction = GlobalDeletionTransaction(
      deletionEpoch: deletionEpoch,
      phase: .requested,
      createdAt: date,
      updatedAt: date,
      retainUntil: retainUntil,
      participants: (peers + processors).sorted(
        by: GlobalDeletionTransaction.participantOrder
      ),
      retryTickets: retryTickets.sorted(
        by: GlobalDeletionTransaction.retryTicketOrder
      )
    )
    guard transaction.isValid else {
      throw GlobalDeletionCoordinatorError.invalidTransaction
    }
    return try await mergeRequest(transaction)
  }

  @discardableResult
  public func prepareFence(
    deletionEpoch: DeletionEpoch,
    at date: Date
  ) async throws -> GlobalDeletionTransaction {
    await acquireMutation()
    defer { releaseMutation() }
    return try await mutate(deletionEpoch: deletionEpoch) { current in
      guard current.phase == .requested else { return current }
      return self.replacing(
        current,
        phase: .deletionFencePrepared,
        updatedAt: date
      )
    }
  }

  @discardableResult
  public func markLocalContentCleared(
    deletionEpoch: DeletionEpoch,
    at date: Date
  ) async throws -> GlobalDeletionTransaction {
    await acquireMutation()
    defer { releaseMutation() }
    return try await mutate(deletionEpoch: deletionEpoch) { current in
      guard current.phase != .requested else {
        throw GlobalDeletionCoordinatorError.fenceNotPrepared
      }
      let phase = self.pendingPhase(for: current.participants)
      return self.replacing(
        current,
        phase: phase == .acknowledged ? .acknowledged : phase,
        updatedAt: date
      )
    }
  }

  @discardableResult
  public func acknowledge(
    kind: GlobalDeletionParticipantKind,
    identifier: String,
    opaqueTicketID: String? = nil,
    deletionEpoch: DeletionEpoch,
    at date: Date
  ) async throws -> GlobalDeletionTransaction {
    await acquireMutation()
    defer { releaseMutation() }
    return try await mutate(deletionEpoch: deletionEpoch) { current in
      guard
        current.phase != .requested,
        current.phase != .deletionFencePrepared
      else {
        throw GlobalDeletionCoordinatorError.localContentNotCleared
      }
      guard
        let index = current.participants.firstIndex(where: {
          $0.kind == kind && $0.identifier == identifier
        })
      else {
        throw GlobalDeletionCoordinatorError.unknownParticipant
      }
      switch kind {
      case .peer:
        guard opaqueTicketID == nil else {
          throw GlobalDeletionCoordinatorError.unexpectedRetryTicket(
            kind: kind
          )
        }
        guard current.participants[index].status != .acknowledged else {
          return current
        }
        var participants = current.participants
        participants[index] = GlobalDeletionParticipant(
          kind: kind,
          identifier: identifier,
          status: .acknowledged,
          acknowledgedAt: date
        )
        participants.sort(by: GlobalDeletionTransaction.participantOrder)
        return self.replacing(
          current,
          phase: self.pendingPhase(for: participants),
          updatedAt: date,
          participants: participants
        )

      case .processor:
        let processorTicketIndices = current.retryTickets.indices.filter {
          current.retryTickets[$0].processorID == identifier
        }
        guard processorTicketIndices.isEmpty == false else {
          guard opaqueTicketID == nil else {
            throw GlobalDeletionCoordinatorError.unknownRetryTicket(
              processorID: identifier,
              opaqueTicketID: opaqueTicketID ?? ""
            )
          }
          guard current.participants[index].status != .acknowledged else {
            return current
          }
          var participants = current.participants
          participants[index] = GlobalDeletionParticipant(
            kind: kind,
            identifier: identifier,
            status: .acknowledged,
            acknowledgedAt: date
          )
          participants.sort(by: GlobalDeletionTransaction.participantOrder)
          return self.replacing(
            current,
            phase: self.pendingPhase(for: participants),
            updatedAt: date,
            participants: participants
          )
        }

        guard let opaqueTicketID else {
          throw GlobalDeletionCoordinatorError.retryTicketRequired(
            processorID: identifier
          )
        }
        guard
          let ticketIndex = processorTicketIndices.first(where: {
            current.retryTickets[$0].opaqueTicketID == opaqueTicketID
          })
        else {
          throw GlobalDeletionCoordinatorError.unknownRetryTicket(
            processorID: identifier,
            opaqueTicketID: opaqueTicketID
          )
        }
        guard
          current.retryTickets[ticketIndex].isAcknowledged == false
        else {
          return current
        }

        var retryTickets = current.retryTickets
        let ticket = retryTickets[ticketIndex]
        retryTickets[ticketIndex] = GlobalDeletionRetryTicket(
          processorID: ticket.processorID,
          opaqueTicketID: ticket.opaqueTicketID,
          expiresAt: ticket.expiresAt,
          acknowledgedAt: date
        )
        let allTicketsAcknowledged = processorTicketIndices.allSatisfy {
          retryTickets[$0].isAcknowledged
        }
        var participants = current.participants
        if allTicketsAcknowledged {
          participants[index] = GlobalDeletionParticipant(
            kind: kind,
            identifier: identifier,
            status: .acknowledged,
            acknowledgedAt: date
          )
        }
        participants.sort(by: GlobalDeletionTransaction.participantOrder)
        return self.replacing(
          current,
          phase: self.pendingPhase(for: participants),
          updatedAt: date,
          participants: participants,
          retryTickets: retryTickets
        )
      }
    }
  }

  public func resolveFreshInstall(
    localRoot: DeletionEpoch,
    trustedExternalFences: [DeletionEpoch],
    offeredProfileRoot: DeletionEpoch
  ) async throws -> FreshInstallDeletionDecision {
    guard
      localRoot.isValid,
      offeredProfileRoot.isValid,
      trustedExternalFences.allSatisfy(\.isValid)
    else {
      throw GlobalDeletionCoordinatorError.invalidTransaction
    }
    var trusted = trustedExternalFences + [localRoot]
    if let stored = try await current()?.deletionEpoch {
      trusted.append(stored)
    }
    let highest = trusted.max() ?? localRoot
    if offeredProfileRoot == highest {
      return .accept(deletionEpoch: highest)
    }
    if offeredProfileRoot < highest {
      return .rejectStaleContent(highestKnown: highest)
    }
    return .requiresRecovery(highestKnown: highest)
  }

  private func participants(
    kind: GlobalDeletionParticipantKind,
    identifiers: [String]
  ) throws -> [GlobalDeletionParticipant] {
    let unique = Set(identifiers)
    guard unique.count == identifiers.count else {
      throw GlobalDeletionCoordinatorError.invalidParticipant
    }
    let values = identifiers.map {
      GlobalDeletionParticipant(
        kind: kind,
        identifier: $0,
        status: .pending
      )
    }
    guard values.allSatisfy(\.isValid) else {
      throw GlobalDeletionCoordinatorError.invalidParticipant
    }
    return values
  }

  private func mutate(
    deletionEpoch: DeletionEpoch,
    transform: (GlobalDeletionTransaction) throws
      -> GlobalDeletionTransaction
  ) async throws -> GlobalDeletionTransaction {
    for attempt in 0..<Self.maximumCASAttempts {
      let snapshot = try await storage.load()
      guard let data = snapshot.data else {
        throw GlobalDeletionCoordinatorError.staleDeletionEpoch
      }
      let current = try codec.decode(data)
      guard current.deletionEpoch == deletionEpoch else {
        throw GlobalDeletionCoordinatorError.staleDeletionEpoch
      }
      let updated = try transform(current)
      guard updated.updatedAt >= current.updatedAt else {
        throw GlobalDeletionCoordinatorError.invalidTransaction
      }
      guard updated != current else { return current }
      let encoded = try codec.encode(updated)
      do {
        _ = try await storage.save(
          encoded,
          replacing: snapshot.revision
        )
        return updated
      } catch GlobalDeletionCoordinatorError.staleStorageRevision
        where attempt + 1 < Self.maximumCASAttempts
      {
        continue
      }
    }
    throw GlobalDeletionCoordinatorError.staleStorageRevision
  }

  private func replacing(
    _ transaction: GlobalDeletionTransaction,
    phase: GlobalDeletionPhase,
    updatedAt: Date,
    participants: [GlobalDeletionParticipant]? = nil,
    retryTickets: [GlobalDeletionRetryTicket]? = nil
  ) -> GlobalDeletionTransaction {
    GlobalDeletionTransaction(
      deletionEpoch: transaction.deletionEpoch,
      phase: phase,
      createdAt: transaction.createdAt,
      updatedAt: max(transaction.updatedAt, updatedAt),
      retainUntil: transaction.retainUntil,
      participants: participants ?? transaction.participants,
      retryTickets: retryTickets ?? transaction.retryTickets
    )
  }

  private func pendingPhase(
    for participants: [GlobalDeletionParticipant]
  ) -> GlobalDeletionPhase {
    if participants.contains(where: {
      $0.kind == .peer && $0.status == .pending
    }) {
      return .peersPending
    }
    if participants.contains(where: {
      $0.kind == .processor && $0.status == .pending
    }) {
      return .processorsPending
    }
    return .acknowledged
  }

  private func mergeRequest(
    _ incoming: GlobalDeletionTransaction
  ) async throws -> GlobalDeletionTransaction {
    for attempt in 0..<Self.maximumCASAttempts {
      let snapshot = try await storage.load()
      let merged: GlobalDeletionTransaction
      if let data = snapshot.data {
        let current = try codec.decode(data)
        if current.deletionEpoch == incoming.deletionEpoch {
          merged = try mergeSameEpoch(
            current: current,
            incoming: incoming
          )
        } else {
          guard current.deletionEpoch < incoming.deletionEpoch else {
            throw GlobalDeletionCoordinatorError.staleDeletionEpoch
          }
          merged = try supersede(
            current: current,
            incoming: incoming
          )
        }
        if merged == current { return current }
      } else {
        merged = incoming
      }
      let encoded = try codec.encode(merged)
      do {
        _ = try await storage.save(
          encoded,
          replacing: snapshot.revision
        )
        return merged
      } catch GlobalDeletionCoordinatorError.staleStorageRevision
        where attempt + 1 < Self.maximumCASAttempts
      {
        continue
      }
    }
    throw GlobalDeletionCoordinatorError.staleStorageRevision
  }

  /// Same-epoch requests merge monotonically: an idempotent retry returns the
  /// current transaction, while newly declared obligations are added without
  /// removing participants or retry capabilities. A newly queued processor
  /// ticket explicitly reopens only that processor's acknowledgement.
  private func mergeSameEpoch(
    current: GlobalDeletionTransaction,
    incoming: GlobalDeletionTransaction
  ) throws -> GlobalDeletionTransaction {
    let existingTicketIDs = Set(
      current.retryTickets.map(
        GlobalDeletionTransaction.retryTicketIdentity
      )
    )
    let newlyQueuedProcessorIDs = Set(
      incoming.retryTickets.compactMap { ticket in
        existingTicketIDs.contains(
          GlobalDeletionTransaction.retryTicketIdentity(ticket)
        )
          ? nil
          : ticket.processorID
      }
    )
    let participants = mergeParticipants(
      retained: current.participants,
      incoming: incoming.participants
    ).map { participant in
      guard
        participant.kind == .processor,
        newlyQueuedProcessorIDs.contains(participant.identifier)
      else {
        return participant
      }
      return GlobalDeletionParticipant(
        kind: participant.kind,
        identifier: participant.identifier,
        status: .pending
      )
    }
    let tickets = try mergeRetryTickets(
      retained: current.retryTickets,
      incoming: incoming.retryTickets
    )
    let phase =
      current.localContentWasCleared
      ? pendingPhase(for: participants)
      : current.phase
    return GlobalDeletionTransaction(
      deletionEpoch: current.deletionEpoch,
      phase: phase,
      createdAt: current.createdAt,
      updatedAt: max(current.updatedAt, incoming.updatedAt),
      retainUntil: max(current.retainUntil, incoming.retainUntil),
      participants: participants,
      retryTickets: tickets
    )
  }

  /// A newer epoch occupies the same durable slot but inherits every unserved
  /// remote obligation from the superseded epoch. Processor tickets form a
  /// small deterministic queue, allowing an adapter to finish both deletions
  /// before acknowledging that processor once.
  private func supersede(
    current: GlobalDeletionTransaction,
    incoming: GlobalDeletionTransaction
  ) throws -> GlobalDeletionTransaction {
    let inherited = current.participants.filter {
      $0.status == .pending
    }
    let inheritedProcessorIDs = Set(
      inherited.compactMap {
        $0.kind == .processor ? $0.identifier : nil
      }
    )
    let inheritedTickets = current.retryTickets.filter {
      inheritedProcessorIDs.contains($0.processorID)
    }
    let participants = mergeParticipants(
      retained: inherited,
      incoming: incoming.participants
    ).map {
      GlobalDeletionParticipant(
        kind: $0.kind,
        identifier: $0.identifier,
        status: .pending
      )
    }
    let tickets = try mergeRetryTickets(
      retained: inheritedTickets,
      incoming: incoming.retryTickets
    )
    let inheritedObligationExists =
      inherited.isEmpty == false || inheritedTickets.isEmpty == false
    return GlobalDeletionTransaction(
      deletionEpoch: incoming.deletionEpoch,
      phase: .requested,
      createdAt: inheritedObligationExists
        ? min(current.createdAt, incoming.createdAt)
        : incoming.createdAt,
      updatedAt: incoming.updatedAt,
      retainUntil: inheritedObligationExists
        ? max(current.retainUntil, incoming.retainUntil)
        : incoming.retainUntil,
      participants: participants,
      retryTickets: tickets
    )
  }

  private func mergeParticipants(
    retained: [GlobalDeletionParticipant],
    incoming: [GlobalDeletionParticipant]
  ) -> [GlobalDeletionParticipant] {
    var merged: [String: GlobalDeletionParticipant] = [:]
    for participant in retained {
      merged[participantKey(participant)] = participant
    }
    for participant in incoming {
      let key = participantKey(participant)
      if merged[key] == nil {
        merged[key] = participant
      }
    }
    return merged.values.sorted(
      by: GlobalDeletionTransaction.participantOrder
    )
  }

  private func mergeRetryTickets(
    retained: [GlobalDeletionRetryTicket],
    incoming: [GlobalDeletionRetryTicket]
  ) throws -> [GlobalDeletionRetryTicket] {
    var merged: [String: GlobalDeletionRetryTicket] = [:]
    for ticket in retained + incoming {
      let key = GlobalDeletionTransaction.retryTicketIdentity(ticket)
      if let existing = merged[key] {
        guard existing.expiresAt == ticket.expiresAt else {
          throw GlobalDeletionCoordinatorError.conflictingRetryTicket(
            processorID: ticket.processorID,
            opaqueTicketID: ticket.opaqueTicketID
          )
        }
        let acknowledgedAt = [
          existing.acknowledgedAt,
          ticket.acknowledgedAt,
        ].compactMap { $0 }.min()
        merged[key] = GlobalDeletionRetryTicket(
          processorID: existing.processorID,
          opaqueTicketID: existing.opaqueTicketID,
          expiresAt: existing.expiresAt,
          acknowledgedAt: acknowledgedAt
        )
        continue
      }
      merged[key] = ticket
    }
    return merged.values.sorted(
      by: GlobalDeletionTransaction.retryTicketOrder
    )
  }

  private func participantKey(
    _ participant: GlobalDeletionParticipant
  ) -> String {
    "\(participant.kind.rawValue.unicodeScalars.count):"
      + "\(participant.kind.rawValue)"
      + "\(participant.identifier.unicodeScalars.count):"
      + participant.identifier
  }

  private func acquireMutation() async {
    guard mutationIsActive else {
      mutationIsActive = true
      return
    }
    await withCheckedContinuation { continuation in
      mutationWaiters.append(continuation)
    }
  }

  private func releaseMutation() {
    guard mutationWaiters.isEmpty == false else {
      mutationIsActive = false
      return
    }
    mutationWaiters.removeFirst().resume()
  }
}

extension GlobalDeletionTransaction {
  fileprivate var localContentWasCleared: Bool {
    switch phase {
    case .requested, .deletionFencePrepared:
      false
    case .localContentCleared, .peersPending, .processorsPending,
      .acknowledged:
      true
    }
  }
}
