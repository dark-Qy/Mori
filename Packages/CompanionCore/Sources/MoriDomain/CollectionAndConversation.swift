import Foundation

public enum CosmeticSlot: String, CaseIterable, Hashable, Codable, Sendable {
  case outfit
  case accessory
  case scene
}

public struct CosmeticCatalogItem: Hashable, Codable, Sendable {
  public let id: CosmeticID
  public let slot: CosmeticSlot
  public let coinPrice: Int

  public init(id: CosmeticID, slot: CosmeticSlot, coinPrice: Int) {
    self.id = id
    self.slot = slot
    self.coinPrice = coinPrice
  }

  public var isValid: Bool { id.isValid && coinPrice > 0 }
}

public struct CollectionOwnershipRecord: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<CollectionOwnershipID>
  public let cosmeticID: CosmeticID
  public let slot: CosmeticSlot
  public let acquiredAt: Date
  public let purchaseTransactionID: CoinTransactionID?
  public let revision: LamportRevision

  public init(
    header: ProfileScopedRecordHeader<CollectionOwnershipID>,
    cosmeticID: CosmeticID,
    slot: CosmeticSlot,
    acquiredAt: Date,
    purchaseTransactionID: CoinTransactionID?,
    revision: LamportRevision
  ) {
    self.header = header
    self.cosmeticID = cosmeticID
    self.slot = slot
    self.acquiredAt = acquiredAt
    self.purchaseTransactionID = purchaseTransactionID
    self.revision = revision
  }
}

/// The indivisible synchronized form of a cosmetic purchase. A debit and its
/// ownership grant must never travel as separate experience events.
public struct CollectionPurchaseRecord: Hashable, Codable, Sendable {
  public let item: CosmeticCatalogItem
  public let ownership: CollectionOwnershipRecord
  public let transaction: CoinTransaction

  public init(
    item: CosmeticCatalogItem,
    ownership: CollectionOwnershipRecord,
    transaction: CoinTransaction
  ) {
    self.item = item
    self.ownership = ownership
    self.transaction = transaction
  }

  public func validate(in profile: RuntimeProfile) -> MoriDomainRejection? {
    guard
      item.isValid,
      ownership.header.schemaVersion == 1,
      ownership.header.scopeMatches(profile),
      ownership.header.recordID.isValid,
      ownership.cosmeticID == item.id,
      ownership.slot == item.slot,
      ownership.purchaseTransactionID == transaction.header.recordID,
      ownership.revision.isValid
    else {
      return .invalidRecord
    }
    if let rejection = transaction.validate(in: profile) {
      return rejection
    }
    guard
      case .cosmeticPurchase(item.id) = transaction.reason,
      transaction.direction == .debit,
      transaction.amount == item.coinPrice
    else {
      return .invalidRecord
    }
    return nil
  }
}

public struct CollectionTransition: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<CollectionTransitionID>
  public let cosmeticID: CosmeticID
  public let slot: CosmeticSlot
  public let revision: LamportRevision

  public init(
    header: ProfileScopedRecordHeader<CollectionTransitionID>,
    cosmeticID: CosmeticID,
    slot: CosmeticSlot,
    revision: LamportRevision
  ) {
    self.header = header
    self.cosmeticID = cosmeticID
    self.slot = slot
    self.revision = revision
  }
}

public struct EquippedCosmetic: Hashable, Codable, Sendable {
  public let cosmeticID: CosmeticID
  public let revision: LamportRevision
  public let transitionID: CollectionTransitionID

  public init(
    cosmeticID: CosmeticID,
    revision: LamportRevision,
    transitionID: CollectionTransitionID
  ) {
    self.cosmeticID = cosmeticID
    self.revision = revision
    self.transitionID = transitionID
  }
}

public struct CollectionState: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<CollectionID>
  public private(set) var ownership: [CollectionOwnershipRecord]
  public private(set) var equipped: [CosmeticSlot: EquippedCosmetic]

  public init(
    header: ProfileScopedRecordHeader<CollectionID>,
    ownership: [CollectionOwnershipRecord] = [],
    equipped: [CosmeticSlot: EquippedCosmetic] = [:]
  ) {
    self.header = header
    self.ownership = ownership
    self.equipped = equipped
  }

  public func owns(_ cosmeticID: CosmeticID) -> Bool {
    ownership.contains { $0.cosmeticID == cosmeticID }
  }

  public func validate(
    in profile: RuntimeProfile,
    coinLedger: CoinLedger
  ) -> MoriDomainRejection? {
    guard
      header.schemaVersion == 1,
      header.recordID.isValid,
      header.scopeMatches(profile)
    else {
      return .invalidRecord
    }
    var ownershipIDs: Set<CollectionOwnershipID> = []
    var cosmeticIDs: Set<CosmeticID> = []
    for record in ownership {
      guard
        record.header.schemaVersion == 1,
        record.header.scopeMatches(profile),
        record.header.recordID.isValid,
        record.cosmeticID.isValid,
        record.revision.isValid,
        ownershipIDs.insert(record.header.recordID).inserted,
        cosmeticIDs.insert(record.cosmeticID).inserted
      else {
        return .invalidRecord
      }
      if let transactionID = record.purchaseTransactionID {
        guard
          let transaction = coinLedger.transactions.first(where: {
            $0.header.recordID == transactionID
          }),
          case .cosmeticPurchase(record.cosmeticID) = transaction.reason,
          transaction.direction == .debit
        else {
          return .invalidRecord
        }
      }
    }
    for (slot, cosmetic) in equipped {
      guard
        cosmetic.cosmeticID.isValid,
        cosmetic.revision.isValid,
        cosmetic.transitionID.isValid,
        ownership.contains(where: {
          $0.cosmeticID == cosmetic.cosmeticID && $0.slot == slot
        })
      else {
        return .invalidRecord
      }
    }
    return nil
  }

  public mutating func applyOwnership(
    _ record: CollectionOwnershipRecord,
    in profile: RuntimeProfile
  ) -> MutationResult {
    guard header.scopeMatches(profile), record.header.scopeMatches(profile) else {
      return .rejected(.profileMismatch)
    }
    guard record.header.recordID.isValid, record.cosmeticID.isValid, record.revision.isValid else {
      return .rejected(.invalidRecord)
    }
    if let existing = ownership.first(where: { $0.header.recordID == record.header.recordID }) {
      return existing == record ? .duplicate : .rejected(.conflictingDuplicate)
    }
    guard owns(record.cosmeticID) == false else { return .rejected(.itemAlreadyOwned) }
    ownership.append(record)
    ownership.sort {
      if $0.revision != $1.revision { return $0.revision < $1.revision }
      return $0.header.recordID < $1.header.recordID
    }
    return .applied
  }

  mutating func replacePurchaseOwnership(
    _ existing: CollectionOwnershipRecord,
    with candidate: CollectionOwnershipRecord,
    in profile: RuntimeProfile
  ) -> MutationResult {
    guard
      header.scopeMatches(profile),
      existing.cosmeticID == candidate.cosmeticID,
      existing.slot == candidate.slot,
      candidate.header.scopeMatches(profile),
      candidate.header.recordID.isValid,
      candidate.purchaseTransactionID != nil,
      candidate.revision.isValid
    else {
      return .rejected(.invalidRecord)
    }
    guard
      let index = ownership.firstIndex(where: {
        $0.header.recordID == existing.header.recordID
      })
    else {
      return .rejected(.invalidRecord)
    }
    if existing == candidate { return .duplicate }
    let candidateWins: Bool
    if candidate.revision != existing.revision {
      candidateWins = candidate.revision < existing.revision
    } else {
      candidateWins = candidate.header.recordID < existing.header.recordID
    }
    guard candidateWins else { return .duplicate }
    ownership[index] = candidate
    ownership.sort {
      if $0.revision != $1.revision { return $0.revision < $1.revision }
      return $0.header.recordID < $1.header.recordID
    }
    return .applied
  }

  public mutating func equip(
    _ transition: CollectionTransition,
    catalogItem: CosmeticCatalogItem,
    in profile: RuntimeProfile
  ) -> MutationResult {
    guard header.scopeMatches(profile), transition.header.scopeMatches(profile) else {
      return .rejected(.profileMismatch)
    }
    guard
      transition.header.recordID.isValid,
      transition.cosmeticID == catalogItem.id,
      transition.slot == catalogItem.slot,
      transition.revision.isValid
    else {
      return .rejected(.invalidRecord)
    }
    guard
      let owned = ownership.first(where: { $0.cosmeticID == transition.cosmeticID }),
      owned.slot == transition.slot
    else {
      return .rejected(.itemNotOwned)
    }
    if let current = equipped[transition.slot] {
      if current.transitionID == transition.header.recordID {
        return current.cosmeticID == transition.cosmeticID
          ? .duplicate
          : .rejected(.conflictingDuplicate)
      }
      guard current.revision < transition.revision else { return .duplicate }
    }
    equipped[transition.slot] = EquippedCosmetic(
      cosmeticID: transition.cosmeticID,
      revision: transition.revision,
      transitionID: transition.header.recordID
    )
    return .applied
  }

  public mutating func equip(
    _ transition: CollectionTransition,
    in profile: RuntimeProfile
  ) -> MutationResult {
    guard
      let owned = ownership.first(where: { $0.cosmeticID == transition.cosmeticID })
    else {
      return .rejected(.itemNotOwned)
    }
    return equip(
      transition,
      catalogItem: CosmeticCatalogItem(id: owned.cosmeticID, slot: owned.slot, coinPrice: 1),
      in: profile
    )
  }
}

public struct CollectionPurchaseResult: Hashable, Codable, Sendable {
  public let collection: CollectionState
  public let coinLedger: CoinLedger

  public init(collection: CollectionState, coinLedger: CoinLedger) {
    self.collection = collection
    self.coinLedger = coinLedger
  }
}

public enum CollectionPurchaseOutcome: Hashable, Codable, Sendable {
  case purchased(CollectionPurchaseResult)
  case duplicate
  case rejected(MoriDomainRejection)
}

public enum CollectionReducer {
  public static func purchase(
    item: CosmeticCatalogItem,
    ownership: CollectionOwnershipRecord,
    transaction: CoinTransaction,
    collection: CollectionState,
    coinLedger: CoinLedger,
    profile: RuntimeProfile
  ) -> CollectionPurchaseOutcome {
    let purchase = CollectionPurchaseRecord(
      item: item,
      ownership: ownership,
      transaction: transaction
    )
    if let rejection = purchase.validate(in: profile) {
      return .rejected(rejection)
    }
    if let existingOwnership = collection.ownership.first(where: {
      $0.cosmeticID == item.id
    }) {
      guard let existingTransactionID = existingOwnership.purchaseTransactionID else {
        return .duplicate
      }
      var updatedCollection = collection
      switch updatedCollection.replacePurchaseOwnership(
        existingOwnership,
        with: ownership,
        in: profile
      ) {
      case .duplicate:
        return .duplicate
      case .rejected(let reason):
        return .rejected(reason)
      case .applied:
        break
      }
      var updatedLedger = coinLedger
      switch updatedLedger.replaceCosmeticPurchase(
        existingTransactionID,
        with: transaction,
        cosmeticID: item.id,
        in: profile
      ) {
      case .applied:
        return .purchased(
          CollectionPurchaseResult(collection: updatedCollection, coinLedger: updatedLedger)
        )
      case .duplicate:
        return .duplicate
      case .rejected(let reason):
        return .rejected(reason)
      }
    }

    var updatedLedger = coinLedger
    switch updatedLedger.apply(transaction, in: profile) {
    case .applied:
      break
    case .duplicate:
      break
    case .rejected(let reason):
      return .rejected(reason)
    }
    var updatedCollection = collection
    switch updatedCollection.applyOwnership(ownership, in: profile) {
    case .applied:
      return .purchased(
        CollectionPurchaseResult(collection: updatedCollection, coinLedger: updatedLedger)
      )
    case .duplicate:
      return .duplicate
    case .rejected(let reason):
      return .rejected(reason)
    }
  }
}

public struct IdentitySelectionRecord: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<IdentitySelectionID>
  public let identity: MoriIdentity
  public let revision: LamportRevision

  public init(
    header: ProfileScopedRecordHeader<IdentitySelectionID>,
    identity: MoriIdentity,
    revision: LamportRevision
  ) {
    self.header = header
    self.identity = identity
    self.revision = revision
  }
}

public enum ConversationRole: String, Hashable, Codable, Sendable {
  case user
  case mori
  case localSystem
}

public struct ConversationTransition: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<ConversationTransitionID>
  public let recordID: ConversationRecordID
  public let revision: LamportRevision
  public let deletedAt: Date

  public init(
    header: ProfileScopedRecordHeader<ConversationTransitionID>,
    recordID: ConversationRecordID,
    revision: LamportRevision,
    deletedAt: Date
  ) {
    self.header = header
    self.recordID = recordID
    self.revision = revision
    self.deletedAt = deletedAt
  }
}

public struct ConversationRecord: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<ConversationRecordID>
  public let conversationID: ConversationID
  public let role: ConversationRole
  public private(set) var content: String
  public let localTime: Date
  public private(set) var referencedMemoryIDs: [MemoryID]
  public let revision: LamportRevision
  public private(set) var deletedAt: Date?
  public private(set) var deletionRevision: LamportRevision?
  public private(set) var deletionTransitionID: ConversationTransitionID?

  public init(
    header: ProfileScopedRecordHeader<ConversationRecordID>,
    conversationID: ConversationID,
    role: ConversationRole,
    content: String,
    localTime: Date,
    referencedMemoryIDs: [MemoryID],
    revision: LamportRevision,
    deletedAt: Date? = nil,
    deletionRevision: LamportRevision? = nil,
    deletionTransitionID: ConversationTransitionID? = nil
  ) {
    self.header = header
    self.conversationID = conversationID
    self.role = role
    self.content = content
    self.localTime = localTime
    self.referencedMemoryIDs = referencedMemoryIDs
    self.revision = revision
    self.deletedAt = deletedAt
    self.deletionRevision = deletionRevision
    self.deletionTransitionID = deletionTransitionID
  }

  public func validate(in profile: RuntimeProfile) -> MoriDomainRejection? {
    guard
      header.schemaVersion == 1,
      header.scopeMatches(profile),
      header.recordID.isValid,
      conversationID.isValid,
      revision.isValid,
      referencedMemoryIDs.allSatisfy(\.isValid),
      (deletedAt == nil) == (deletionRevision == nil),
      (deletedAt == nil) == (deletionTransitionID == nil),
      deletionRevision?.isValid ?? true,
      deletionTransitionID?.isValid ?? true
    else {
      return .invalidRecord
    }
    if deletedAt == nil {
      guard content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        return .invalidRecord
      }
    } else {
      guard content.isEmpty else { return .invalidRecord }
    }
    return nil
  }

  public var isDeleted: Bool { deletionRevision != nil }

  public mutating func apply(
    _ transition: ConversationTransition,
    in profile: RuntimeProfile
  ) -> MutationResult {
    guard header.scopeMatches(profile), transition.header.scopeMatches(profile) else {
      return .rejected(.profileMismatch)
    }
    guard
      transition.header.recordID.isValid,
      transition.recordID == header.recordID,
      transition.revision.isValid
    else {
      return .rejected(.invalidRecord)
    }
    if transition.header.recordID == deletionTransitionID { return .duplicate }
    if let current = deletionRevision {
      guard current != transition.revision else {
        return .rejected(.conflictingDuplicate)
      }
      guard current < transition.revision else { return .duplicate }
    }
    deletedAt = transition.deletedAt
    deletionRevision = transition.revision
    deletionTransitionID = transition.header.recordID
    content = ""
    referencedMemoryIDs = []
    return .applied
  }
}

public struct SelectedMemoryExcerpt: Hashable, Codable, Sendable {
  public let memoryID: MemoryID
  public let text: String

  public init(memoryID: MemoryID, text: String) {
    self.memoryID = memoryID
    self.text = text
  }

  public var isValid: Bool {
    memoryID.isValid && text.unicodeScalars.count <= 500
  }
}

public struct AppAddedChatContext: Hashable, Codable, Sendable {
  public let identity: MoriIdentity
  public let tone: MoriTone
  public let approvedEventIDs: [EventID]
  public let memoryReferences: [MemoryID]
  public let selectedMemoryExcerpt: SelectedMemoryExcerpt?

  public init(
    identity: MoriIdentity,
    tone: MoriTone,
    approvedEventIDs: [EventID],
    memoryReferences: [MemoryID],
    selectedMemoryExcerpt: SelectedMemoryExcerpt?
  ) {
    self.identity = identity
    self.tone = tone
    self.approvedEventIDs = approvedEventIDs
    self.memoryReferences = memoryReferences
    self.selectedMemoryExcerpt = selectedMemoryExcerpt
  }

  public var isValid: Bool {
    approvedEventIDs.allSatisfy(\.isValid)
      && memoryReferences.allSatisfy(\.isValid)
      && (selectedMemoryExcerpt?.isValid ?? true)
      && selectedMemoryExcerpt.map { memoryReferences.contains($0.memoryID) } ?? true
  }
}

public struct UserConversationContext: Hashable, Codable, Sendable {
  public let explicitMessage: String
  public let recentMessages: [ConversationRecord]

  public init(explicitMessage: String, recentMessages: [ConversationRecord]) {
    self.explicitMessage = explicitMessage
    self.recentMessages = recentMessages
  }
}

public enum ChatCandidate: Hashable, Codable, Sendable {
  case replyText(String)
  case taskProposal(kind: MoriTaskKind, sourceEventID: EventID)
}

public enum ConversationBoundary {
  public static func validate(
    userContext: UserConversationContext,
    appContext: AppAddedChatContext,
    profile: RuntimeProfile,
    maximumRecentMessages: Int = 12,
    maximumMessageScalars: Int = 4_000
  ) -> MoriDomainRejection? {
    let message = userContext.explicitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard message.isEmpty == false, message.unicodeScalars.count <= maximumMessageScalars else {
      return .invalidRecord
    }
    guard userContext.recentMessages.count <= maximumRecentMessages, appContext.isValid else {
      return .invalidRecord
    }
    guard
      userContext.recentMessages.allSatisfy({
        $0.header.scopeMatches(profile)
      })
    else {
      return .profileMismatch
    }
    guard
      userContext.recentMessages.allSatisfy({
        $0.validate(in: profile) == nil
          && ($0.role == .user || $0.role == .mori)
          && $0.isDeleted == false
          && $0.content.unicodeScalars.count <= maximumMessageScalars
      })
    else {
      return .invalidRecord
    }
    guard
      Set(userContext.recentMessages.map(\.conversationID)).count <= 1,
      Set(userContext.recentMessages.map(\.header.recordID)).count
        == userContext.recentMessages.count,
      userContext.recentMessages.map(\.revision)
        == userContext.recentMessages.map(\.revision).sorted()
    else {
      return .invalidRecord
    }
    return nil
  }

  public static func acceptsCandidate(
    _ candidate: ChatCandidate,
    approvedEvents: Set<EventID>,
    maximumReplyScalars: Int = 2_000
  ) -> Bool {
    switch candidate {
    case .replyText(let text):
      return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        && text.unicodeScalars.count <= maximumReplyScalars
    case .taskProposal(_, let sourceEventID):
      // This remains untrusted input. The task issuance policy must still create
      // the actual TaskInstance.
      return approvedEvents.contains(sourceEventID)
    }
  }
}
