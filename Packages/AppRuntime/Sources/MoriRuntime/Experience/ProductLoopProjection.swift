import CryptoKit
import Foundation
import MoriDomain
import MoriPersistence

/// A stable, content-free projection of the state needed to verify a Mori product loop.
///
/// The projection intentionally excludes evidence values, memory narrative, letter text,
/// conversation content, and wall-clock timestamps. It is safe to compare across peers or
/// include in sanitized test evidence, while typed record identifiers and logical revisions
/// still expose authority or convergence mistakes.
public struct ProductLoopProjection: Hashable, Codable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public enum FactAuthorization: Hashable, Codable, Sendable {
    case displayOnly
    case companion(SensingEpoch)
  }

  public struct Fact: Hashable, Codable, Sendable {
    public let id: EvidenceID
    public let kind: EvidenceKind
    public let provenance: EvidenceProvenance
    public let authorization: FactAuthorization

    fileprivate init(_ record: DerivedFactRecord) {
      id = record.header.recordID
      kind = record.value.kind
      provenance = record.provenance
      authorization =
        switch record.authorization {
        case .displayOnly:
          .displayOnly
        case .companion(let epoch):
          .companion(epoch)
        }
    }
  }

  public enum ReminderLifecycle: Hashable, Codable, Sendable {
    case pending
    case presented
    case expired
    case replaced(by: EventID)
  }

  public struct Event: Hashable, Codable, Sendable {
    public let id: EventID
    public let kind: PassiveEventKind
    public let sensingEpoch: SensingEpoch
    public let confidence: ConfidenceBand
    public let evidence: [EvidenceReference]
    public let memoryEligibility: MemoryEligibility
    public let taskCooldownKey: TaskCooldownKey?
    public let reminderLifecycle: ReminderLifecycle
    public let reminderRevision: LamportRevision

    fileprivate init(_ event: PassiveCompanionEvent) {
      id = event.header.recordID
      kind = event.kind
      sensingEpoch = event.sensingEpoch
      confidence = event.confidence
      evidence = event.evidence.sorted {
        if $0.kind != $1.kind {
          return $0.kind.rawValue < $1.kind.rawValue
        }
        return $0.id < $1.id
      }
      memoryEligibility = event.memoryEligibility
      taskCooldownKey = event.taskCooldownKey
      reminderLifecycle =
        switch event.reminderState {
        case .pending:
          .pending
        case .presented:
          .presented
        case .expired:
          .expired
        case .replaced(let eventID, _):
          .replaced(by: eventID)
        }
      reminderRevision = event.reminderRevision
    }
  }

  public enum TaskLifecycle: Hashable, Codable, Sendable {
    case active
    case completed(method: TaskCompletionMethod)
    case expired
  }

  public struct Task: Hashable, Codable, Sendable {
    public let id: TaskID
    public let sourceEventID: EventID
    public let kind: MoriTaskKind
    public let cooldownKey: TaskCooldownKey
    public let recommendationPriority: RecommendationPriority
    public let completionPolicy: TaskCompletionPolicy
    public let rewardTier: CoinRewardTier
    public let settlementID: TaskSettlementID
    public let lifecycle: TaskLifecycle
    public let issuedRevision: LamportRevision
    public let lifecycleRevision: LamportRevision
    public let winningTransitionID: TaskTransitionID?

    fileprivate init(_ task: TaskInstance) {
      id = task.header.recordID
      sourceEventID = task.sourceEventID
      kind = task.kind
      cooldownKey = task.cooldownKey
      recommendationPriority = task.recommendationPriority
      completionPolicy = task.completionPolicy
      rewardTier = task.rewardTier
      settlementID = task.settlementID
      lifecycle =
        switch task.lifecycle {
        case .active:
          .active
        case .completed(let method, _):
          .completed(method: method)
        case .expired:
          .expired
        }
      issuedRevision = task.issuedRevision
      lifecycleRevision = task.lifecycleRevision
      winningTransitionID = task.winningTransitionID
    }
  }

  public struct Cooldown: Hashable, Codable, Sendable {
    public let id: TaskCooldownID
    public let key: TaskCooldownKey
    public let duration: TimeInterval
    public let revision: LamportRevision

    fileprivate init(_ cooldown: TaskCooldownRecord) {
      id = cooldown.header.recordID
      key = cooldown.key
      duration = cooldown.duration
      revision = cooldown.revision
    }
  }

  public enum CoinReason: Hashable, Codable, Sendable {
    case taskReward(TaskSettlementID)
    case welcomeGrant(schemaVersion: UInt16)
    case cosmeticPurchase(CosmeticID)
    case reversal(CoinTransactionID)
    case migration(schemaVersion: UInt16)
  }

  public struct CoinEntry: Hashable, Codable, Sendable {
    public let id: CoinTransactionID
    public let revision: LamportRevision
    public let direction: CoinTransactionDirection
    public let amount: Int
    public let reason: CoinReason

    fileprivate init(_ transaction: CoinTransaction) {
      id = transaction.header.recordID
      revision = transaction.revision
      direction = transaction.direction
      amount = transaction.amount
      reason =
        switch transaction.reason {
        case .taskReward(let settlementID):
          .taskReward(settlementID)
        case .welcomeGrant(let schemaVersion):
          .welcomeGrant(schemaVersion: schemaVersion)
        case .cosmeticPurchase(let cosmeticID):
          .cosmeticPurchase(cosmeticID)
        case .reversal(let transactionID):
          .reversal(transactionID)
        case .migration(let schemaVersion):
          .migration(schemaVersion: schemaVersion)
        }
    }
  }

  public struct CoinState: Hashable, Codable, Sendable {
    public let ledgerID: CoinLedgerID
    public let balance: Int
    public let transactions: [CoinEntry]

    fileprivate init(_ ledger: CoinLedger) {
      ledgerID = ledger.header.recordID
      balance = ledger.balance
      transactions = ledger.transactions
        .map(CoinEntry.init)
        .sorted { $0.id < $1.id }
    }
  }

  public struct Ownership: Hashable, Codable, Sendable {
    public let id: CollectionOwnershipID
    public let cosmeticID: CosmeticID
    public let slot: CosmeticSlot
    public let purchaseTransactionID: CoinTransactionID?
    public let revision: LamportRevision

    fileprivate init(_ ownership: CollectionOwnershipRecord) {
      id = ownership.header.recordID
      cosmeticID = ownership.cosmeticID
      slot = ownership.slot
      purchaseTransactionID = ownership.purchaseTransactionID
      revision = ownership.revision
    }
  }

  public struct Equipped: Hashable, Codable, Sendable {
    public let slot: CosmeticSlot
    public let cosmeticID: CosmeticID
    public let revision: LamportRevision
    public let transitionID: CollectionTransitionID

    fileprivate init(slot: CosmeticSlot, cosmetic: EquippedCosmetic) {
      self.slot = slot
      cosmeticID = cosmetic.cosmeticID
      revision = cosmetic.revision
      transitionID = cosmetic.transitionID
    }
  }

  public struct Collection: Hashable, Codable, Sendable {
    public let collectionID: CollectionID
    public let ownership: [Ownership]
    public let equipped: [Equipped]

    fileprivate init(_ collection: CollectionState) {
      collectionID = collection.header.recordID
      ownership = collection.ownership
        .map(Ownership.init)
        .sorted { $0.id < $1.id }
      equipped = collection.equipped
        .map { Equipped(slot: $0.key, cosmetic: $0.value) }
        .sorted {
          if $0.slot != $1.slot {
            return $0.slot.rawValue < $1.slot.rawValue
          }
          return $0.cosmeticID < $1.cosmeticID
        }
    }
  }

  public enum MemoryVisibility: String, Hashable, Codable, Sendable {
    case draft
    case visible
    case deleted
  }

  public struct Memory: Hashable, Codable, Sendable {
    public let id: MemoryID
    public let visibility: MemoryVisibility
    public let factCount: Int
    public let authoredRevision: LamportRevision
    public let deletionRevision: LamportRevision?
    public let winningTransitionID: MemoryTransitionID?

    fileprivate init(_ memory: MemoryRecord) {
      id = memory.header.recordID
      authoredRevision = memory.authoredRevision
      winningTransitionID = memory.winningTransitionID
      switch memory.lifecycle {
      case .draft:
        visibility = .draft
        factCount = 0
        deletionRevision = nil
      case .sealed(let content):
        visibility = .visible
        factCount = content.facts.count
        deletionRevision = nil
      case .deleted(_, let revision):
        visibility = .deleted
        factCount = 0
        deletionRevision = revision
      }
    }
  }

  public enum LetterSource: Hashable, Codable, Sendable {
    case event(EventID)
    case memory(MemoryID)
  }

  public struct Letter: Hashable, Codable, Sendable {
    public let id: LetterID
    public let source: LetterSource
    public let authoredRevision: LamportRevision
    public let isRead: Bool
    public let readRevision: LamportRevision?
    public let readTransitionID: LetterTransitionID?
    public let isDeleted: Bool
    public let deletionRevision: LamportRevision?
    public let deletionTransitionID: LetterTransitionID?

    fileprivate init(_ letter: LetterRecord) {
      id = letter.header.recordID
      source =
        switch letter.source {
        case .event(let eventID):
          .event(eventID)
        case .memory(let memoryID):
          .memory(memoryID)
        }
      authoredRevision = letter.authoredRevision
      isRead = letter.isRead
      readRevision = letter.readRevision
      readTransitionID = letter.readTransitionID
      isDeleted = letter.isDeleted
      deletionRevision = letter.deletionRevision
      deletionTransitionID = letter.deletionTransitionID
    }
  }

  public struct ConversationCounts: Hashable, Codable, Sendable {
    public let total: Int
    public let visible: Int
    public let deleted: Int

    fileprivate init(_ records: [ConversationRecord]) {
      total = records.count
      deleted = records.lazy.filter(\.isDeleted).count
      visible = total - deleted
    }
  }

  public struct Unresolved: Hashable, Codable, Sendable {
    public let eventID: ExperienceEventID
    public let reason: MoriDomainRejection

    fileprivate init(_ rejection: ProfileReplayRejection) {
      eventID = rejection.eventID
      reason = rejection.reason
    }
  }

  public let schemaVersion: UInt16
  public let profile: RuntimeProfile
  public let companionSensingEnabled: Bool
  public let currentSensingEpoch: SensingEpoch
  public let selectedIdentity: MoriIdentity
  public let identityRevision: LamportRevision
  public let tone: MoriTone
  public let facts: [Fact]
  public let events: [Event]
  public let tasks: [Task]
  public let cooldowns: [Cooldown]
  public let coins: CoinState
  public let collection: Collection
  public let memories: [Memory]
  public let letters: [Letter]
  public let conversation: ConversationCounts
  public let unresolved: [Unresolved]
  public let acceptedEventCount: Int
  public let ledgerEventCount: Int

  public init(
    replay: ProfileReplayResult,
    ledgerEventCount: Int
  ) {
    let state = replay.state
    schemaVersion = Self.currentSchemaVersion
    profile = state.runtimeProfile
    companionSensingEnabled = state.companionSensingEnabled
    currentSensingEpoch = state.currentSensingEpoch
    selectedIdentity = state.selectedIdentity
    identityRevision = state.identityRevision
    tone = state.tone
    facts = state.derivedFacts
      .map(Fact.init)
      .sorted { $0.id < $1.id }
    events = state.passiveEvents
      .map(Event.init)
      .sorted { $0.id < $1.id }
    tasks = state.tasks
      .map(Task.init)
      .sorted { $0.id < $1.id }
    cooldowns = state.cooldowns
      .map(Cooldown.init)
      .sorted { $0.id < $1.id }
    coins = CoinState(state.coinLedger)
    collection = Collection(state.collection)
    memories = state.memories
      .map(Memory.init)
      .sorted { $0.id < $1.id }
    letters = state.letters
      .map(Letter.init)
      .sorted { $0.id < $1.id }
    conversation = ConversationCounts(state.conversation)
    unresolved = replay.unresolved
      .map(Unresolved.init)
      .sorted {
        if $0.eventID != $1.eventID {
          return $0.eventID < $1.eventID
        }
        return $0.reason.rawValue < $1.reason.rawValue
      }
    acceptedEventCount = state.experienceLedger.count
    self.ledgerEventCount = max(0, ledgerEventCount)
  }

  public init(ledger: ProfileLedger) {
    self.init(
      replay: ledger.replay(),
      ledgerEventCount: ledger.envelopes.count
    )
  }

  public func stateDigest() throws -> ProductLoopStateDigest {
    try ProductLoopStateDigest(projection: self)
  }
}

/// A canonical SHA-256 identity for a `ProductLoopProjection`.
///
/// Only the already sanitized projection is encoded, so the digest cannot
/// accidentally serialize narrative, letter, evidence, or conversation text.
public struct ProductLoopStateDigest: Hashable, Codable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let sha256: String

  public init(projection: ProductLoopProjection) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(projection)
    let digest = SHA256.hash(data: data)
    schemaVersion = Self.currentSchemaVersion
    sha256 = digest.map { String(format: "%02x", $0) }.joined()
  }
}
