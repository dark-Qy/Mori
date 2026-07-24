import Foundation

public enum MoriTaskKind: String, CaseIterable, Hashable, Codable, Sendable {
  case walkTogether
  case pauseTogether
  case bedtimeWindDown
  case hydrate
  case mindfulPause
  case exploreNearby
  case reflectOnDay
}

public enum RecommendationPriority: Int, CaseIterable, Hashable, Codable, Sendable, Comparable {
  case low = 0
  case normal = 1
  case recommended = 2

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public enum TaskCompletionPolicy: String, Hashable, Codable, Sendable {
  case automatic
  case userConfirmation
}

public enum TaskCompletionMethod: String, Hashable, Codable, Sendable {
  case automatic
  case userConfirmed
}

public enum CoinRewardTier: Int, CaseIterable, Hashable, Codable, Sendable {
  case smallest = 1
  case standard = 2
  case meaningful = 4
  case rare6 = 6
  case rare7 = 7
  case rare8 = 8
  case rare9 = 9
  case rare10 = 10
}

public enum TaskLifecycleState: Hashable, Codable, Sendable {
  case active
  case completed(method: TaskCompletionMethod, at: Date)
  case expired(at: Date)

  public var isCompleted: Bool {
    if case .completed = self { return true }
    return false
  }

  public var isTerminal: Bool {
    if case .active = self { return false }
    return true
  }
}

public struct TaskInstance: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<TaskID>
  public let sourceEventID: EventID
  public let kind: MoriTaskKind
  public let cooldownKey: TaskCooldownKey
  public let recommendationPriority: RecommendationPriority
  public let completionPolicy: TaskCompletionPolicy
  public let issuedAt: Date
  public let issuedRevision: LamportRevision
  public let cooldownDuration: TimeInterval
  public let expiresAt: Date?
  public let rewardTier: CoinRewardTier
  public let settlementID: TaskSettlementID
  public private(set) var lifecycle: TaskLifecycleState
  public private(set) var lifecycleRevision: LamportRevision
  public private(set) var winningTransitionID: TaskTransitionID?

  public init(
    header: ProfileScopedRecordHeader<TaskID>,
    sourceEventID: EventID,
    kind: MoriTaskKind,
    cooldownKey: TaskCooldownKey,
    recommendationPriority: RecommendationPriority,
    completionPolicy: TaskCompletionPolicy,
    issuedAt: Date,
    issuedRevision: LamportRevision,
    cooldownDuration: TimeInterval,
    expiresAt: Date?,
    rewardTier: CoinRewardTier,
    settlementID: TaskSettlementID,
    lifecycle: TaskLifecycleState = .active,
    lifecycleRevision: LamportRevision,
    winningTransitionID: TaskTransitionID? = nil
  ) {
    self.header = header
    self.sourceEventID = sourceEventID
    self.kind = kind
    self.cooldownKey = cooldownKey
    self.recommendationPriority = recommendationPriority
    self.completionPolicy = completionPolicy
    self.issuedAt = issuedAt
    self.issuedRevision = issuedRevision
    self.cooldownDuration = cooldownDuration
    self.expiresAt = expiresAt
    self.rewardTier = rewardTier
    self.settlementID = settlementID
    self.lifecycle = lifecycle
    self.lifecycleRevision = lifecycleRevision
    self.winningTransitionID = winningTransitionID
  }

  public func validate(in profile: RuntimeProfile) -> MoriDomainRejection? {
    guard header.schemaVersion == 1 else { return .invalidSchema }
    guard
      header.recordID.isValid,
      sourceEventID.isValid,
      cooldownKey.isValid,
      settlementID.isValid,
      issuedRevision.isValid,
      lifecycleRevision.isValid
    else {
      return .invalidIdentifier
    }
    guard header.profileID == profile.id else { return .profileMismatch }
    guard header.profileEpoch == profile.epoch else { return .profileEpochMismatch }
    guard header.deletionEpoch == profile.deletionEpoch else { return .deletionEpochMismatch }
    guard
      cooldownDuration >= 0,
      cooldownDuration.isFinite,
      expiresAt.map({ $0 >= issuedAt }) ?? true,
      lifecycleRevision >= issuedRevision
    else {
      return .invalidRecord
    }
    switch lifecycle {
    case .active:
      guard
        winningTransitionID == nil,
        lifecycleRevision == issuedRevision
      else {
        return .invalidRecord
      }
    case .completed(let method, let at):
      guard
        completionMethodAllowed(method),
        completionIsTimely(at),
        let winningTransitionID,
        winningTransitionID.isValid
      else {
        return .invalidRecord
      }
    case .expired(let at):
      guard
        let expiresAt,
        at >= expiresAt,
        let winningTransitionID,
        winningTransitionID.isValid
      else {
        return .invalidRecord
      }
    }
    return nil
  }

  public mutating func apply(
    _ transition: TaskTransition,
    in profile: RuntimeProfile
  ) -> MutationResult {
    guard transition.header.schemaVersion == 1 else { return .rejected(.invalidSchema) }
    guard header.scopeMatches(profile), transition.header.scopeMatches(profile) else {
      return .rejected(.profileMismatch)
    }
    guard transition.taskID == header.recordID else { return .rejected(.invalidRecord) }
    guard transition.header.recordID.isValid, transition.revision.isValid else {
      return .rejected(.invalidIdentifier)
    }
    guard transition.revision >= issuedRevision else {
      return .rejected(.invalidRecord)
    }
    guard transition.settlementID == settlementID || transition.settlementID == nil else {
      return .rejected(.invalidRecord)
    }
    if transition.header.recordID == winningTransitionID {
      return transition.state == lifecycle ? .duplicate : .rejected(.conflictingDuplicate)
    }

    switch (lifecycle, transition.state) {
    case (.active, .active), (.expired, .active), (.completed, .active):
      return .rejected(.illegalTransition)

    case (.active, let .expired(at)):
      guard transition.settlementID == nil else { return .rejected(.invalidRecord) }
      guard let expiresAt, at >= expiresAt else {
        return .rejected(.illegalTransition)
      }
      lifecycle = transition.state
      lifecycleRevision = transition.revision
      winningTransitionID = transition.header.recordID
      return .applied

    case (.active, let .completed(method, at)):
      guard
        completionMethodAllowed(method),
        completionIsTimely(at),
        transition.settlementID == settlementID
      else {
        return .rejected(.completionNotAllowed)
      }
      lifecycle = transition.state
      lifecycleRevision = transition.revision
      winningTransitionID = transition.header.recordID
      return .applied

    case (.expired, let .completed(method, at)):
      // A completion observed before expiry may arrive after the expiry
      // transition while offline. A genuinely late completion stays expired.
      guard
        completionMethodAllowed(method),
        transition.settlementID == settlementID
      else {
        return .rejected(.completionNotAllowed)
      }
      guard completionIsTimely(at) else { return .duplicate }
      lifecycle = transition.state
      lifecycleRevision = transition.revision
      winningTransitionID = transition.header.recordID
      return .applied

    case (.completed, let .expired(at)):
      guard transition.settlementID == nil, let expiresAt, at >= expiresAt else {
        return .rejected(.illegalTransition)
      }
      // Completion already won. A valid expiry delivered later is a consumed
      // terminal loser and must not remain unresolved.
      return .duplicate

    case (.expired, let .expired(at)):
      guard transition.settlementID == nil, let expiresAt, at >= expiresAt else {
        return .rejected(.illegalTransition)
      }
      return .duplicate

    case (.completed, .completed):
      // Both completion paths share one settlement. Canonical logical order makes
      // the visible method converge without affecting reward idempotency.
      guard transition.settlementID == settlementID else {
        return .rejected(.completionNotAllowed)
      }
      guard case .completed(let method, let at) = transition.state,
        completionMethodAllowed(method)
      else {
        return .rejected(.completionNotAllowed)
      }
      guard completionIsTimely(at) else { return .duplicate }
      if transition.revision < lifecycleRevision {
        lifecycle = transition.state
        lifecycleRevision = transition.revision
        winningTransitionID = transition.header.recordID
        return .applied
      }
      return .duplicate
    }
  }

  private func completionMethodAllowed(_ method: TaskCompletionMethod) -> Bool {
    switch (completionPolicy, method) {
    case (.automatic, .automatic),
      (.automatic, .userConfirmed),
      (.userConfirmation, .userConfirmed):
      return true
    default:
      return false
    }
  }

  private func completionIsTimely(_ date: Date) -> Bool {
    expiresAt.map { date <= $0 } ?? true
  }
}

public struct TaskTransition: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<TaskTransitionID>
  public let taskID: TaskID
  public let revision: LamportRevision
  public let state: TaskLifecycleState
  public let settlementID: TaskSettlementID?

  public init(
    header: ProfileScopedRecordHeader<TaskTransitionID>,
    taskID: TaskID,
    revision: LamportRevision,
    state: TaskLifecycleState,
    settlementID: TaskSettlementID?
  ) {
    self.header = header
    self.taskID = taskID
    self.revision = revision
    self.state = state
    self.settlementID = settlementID
  }
}

public struct TaskCooldownRecord: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<TaskCooldownID>
  public let key: TaskCooldownKey
  public let issuedAt: Date
  public let duration: TimeInterval
  public let revision: LamportRevision

  public init(
    header: ProfileScopedRecordHeader<TaskCooldownID>,
    key: TaskCooldownKey,
    issuedAt: Date,
    duration: TimeInterval,
    revision: LamportRevision
  ) {
    self.header = header
    self.key = key
    self.issuedAt = issuedAt
    self.duration = duration
    self.revision = revision
  }

  public var nextEligibleAt: Date {
    issuedAt.addingTimeInterval(max(0, duration))
  }

  public func permits(issuanceAt date: Date) -> Bool {
    duration >= 0 && date >= nextEligibleAt
  }
}

public enum TaskIssuancePolicy {
  public static func evaluate(
    event: PassiveCompanionEvent,
    candidate: TaskInstance,
    existingTaskForSourceEvent: TaskInstance?,
    cooldown: TaskCooldownRecord?,
    manualTaskHasVisibleSlot: Bool,
    profile: RuntimeProfile,
    sensingEpoch: SensingEpoch
  ) -> MutationResult {
    if let rejection = event.validate(in: profile, sensingEpoch: sensingEpoch) {
      return .rejected(rejection)
    }
    if let rejection = candidate.validate(in: profile) {
      return .rejected(rejection)
    }
    guard candidate.sourceEventID == event.header.recordID else {
      return .rejected(.invalidRecord)
    }
    guard existingTaskForSourceEvent == nil else {
      return existingTaskForSourceEvent == candidate
        ? .duplicate
        : .rejected(.conflictingDuplicate)
    }
    guard candidate.cooldownKey == event.taskCooldownKey else {
      return .rejected(.invalidRecord)
    }
    if let cooldown {
      guard cooldown.header.scopeMatches(profile), cooldown.key == candidate.cooldownKey else {
        return .rejected(.invalidRecord)
      }
      guard cooldown.permits(issuanceAt: candidate.issuedAt) else {
        return .rejected(.cooldownActive)
      }
    }
    switch candidate.completionPolicy {
    case .automatic:
      guard event.confidence >= .high else { return .rejected(.completionNotAllowed) }
    case .userConfirmation:
      guard manualTaskHasVisibleSlot else { return .rejected(.invisibleManualTask) }
    }
    return .applied
  }
}

public enum CoinTransactionDirection: String, Hashable, Codable, Sendable {
  case credit
  case debit
  case neutral
}

public enum CoinTransactionReason: Hashable, Codable, Sendable {
  case taskReward(TaskSettlementID)
  case cosmeticPurchase(CosmeticID)
  case reversal(CoinTransactionID)
  case migration(schemaVersion: UInt16)
}

public struct CoinTransaction: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<CoinTransactionID>
  public let revision: LamportRevision
  public let authoredAt: Date
  public let direction: CoinTransactionDirection
  public let amount: Int
  public let reason: CoinTransactionReason

  public init(
    header: ProfileScopedRecordHeader<CoinTransactionID>,
    revision: LamportRevision,
    authoredAt: Date,
    direction: CoinTransactionDirection,
    amount: Int,
    reason: CoinTransactionReason
  ) {
    self.header = header
    self.revision = revision
    self.authoredAt = authoredAt
    self.direction = direction
    self.amount = amount
    self.reason = reason
  }

  public func validate(in profile: RuntimeProfile) -> MoriDomainRejection? {
    guard header.schemaVersion == 1 else { return .invalidSchema }
    guard header.recordID.isValid, revision.isValid, amount >= 0 else {
      return .invalidRecord
    }
    guard header.profileID == profile.id else { return .profileMismatch }
    guard header.profileEpoch == profile.epoch else { return .profileEpochMismatch }
    guard header.deletionEpoch == profile.deletionEpoch else { return .deletionEpochMismatch }
    switch reason {
    case .taskReward(let settlementID):
      guard direction == .credit, CoinRewardTier(rawValue: amount) != nil, settlementID.isValid
      else {
        return .invalidRewardTier
      }
    case .cosmeticPurchase(let itemID):
      guard direction == .debit, amount > 0, itemID.isValid else { return .invalidRecord }
    case .reversal(let originalID):
      guard direction != .neutral, amount > 0, originalID.isValid else {
        return .invalidRecord
      }
    case .migration:
      guard direction == .neutral, amount == 0 else { return .invalidRecord }
    }
    return nil
  }
}

public struct CoinLedger: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<CoinLedgerID>
  public private(set) var transactions: [CoinTransaction]

  public init(
    header: ProfileScopedRecordHeader<CoinLedgerID>,
    transactions: [CoinTransaction] = []
  ) {
    self.header = header
    self.transactions = transactions
  }

  public var balance: Int {
    var balance = 0
    for transaction in transactions {
      let delta: Int
      switch transaction.direction {
      case .credit: delta = transaction.amount
      case .debit: delta = -transaction.amount
      case .neutral: delta = 0
      }
      let next = balance.addingReportingOverflow(delta)
      if next.overflow {
        return delta >= 0 ? Int.max : Int.min
      }
      balance = next.partialValue
    }
    return balance
  }

  public func validate(in profile: RuntimeProfile) -> MoriDomainRejection? {
    guard header.schemaVersion == 1, header.recordID.isValid, header.scopeMatches(profile) else {
      return .invalidRecord
    }
    return Self.validateCanonicalTransactions(
      transactions.sorted(by: Self.canonicalOrder),
      in: profile
    )
  }

  public mutating func apply(
    _ transaction: CoinTransaction,
    in profile: RuntimeProfile
  ) -> MutationResult {
    guard header.scopeMatches(profile) else { return .rejected(.profileMismatch) }
    if let rejection = transaction.validate(in: profile) {
      return .rejected(rejection)
    }
    if let existing = transactions.first(where: {
      $0.header.recordID == transaction.header.recordID
    }) {
      return existing == transaction ? .duplicate : .rejected(.conflictingDuplicate)
    }
    if case .taskReward(let settlementID) = transaction.reason,
      transactions.contains(where: {
        if case .taskReward(let existingSettlementID) = $0.reason {
          return existingSettlementID == settlementID
        }
        return false
      })
    {
      return .duplicate
    }
    var candidate = transactions
    candidate.append(transaction)
    candidate.sort(by: Self.canonicalOrder)
    if let rejection = Self.validateCanonicalTransactions(candidate, in: profile) {
      return .rejected(rejection)
    }
    transactions = candidate
    return .applied
  }

  mutating func replaceCosmeticPurchase(
    _ existingTransactionID: CoinTransactionID,
    with transaction: CoinTransaction,
    cosmeticID: CosmeticID,
    in profile: RuntimeProfile
  ) -> MutationResult {
    guard
      let existingIndex = transactions.firstIndex(where: {
        $0.header.recordID == existingTransactionID
      })
    else {
      return .rejected(.invalidRecord)
    }
    let existing = transactions[existingIndex]
    guard
      case .cosmeticPurchase(cosmeticID) = existing.reason,
      existing.direction == .debit,
      case .cosmeticPurchase(cosmeticID) = transaction.reason,
      transaction.direction == .debit
    else {
      return .rejected(.invalidRecord)
    }
    if existing.header.recordID == transaction.header.recordID {
      return existing == transaction ? .duplicate : .rejected(.conflictingDuplicate)
    }
    guard
      transactions.contains(where: {
        $0.header.recordID == transaction.header.recordID
      }) == false
    else {
      return .rejected(.conflictingDuplicate)
    }

    var candidateTransactions = transactions
    candidateTransactions.remove(at: existingIndex)
    candidateTransactions.append(transaction)
    candidateTransactions.sort(by: Self.canonicalOrder)
    let candidate = CoinLedger(header: header, transactions: candidateTransactions)
    if let rejection = candidate.validate(in: profile) {
      return .rejected(rejection)
    }
    transactions = candidateTransactions
    return .applied
  }

  private static func canonicalOrder(
    _ lhs: CoinTransaction,
    _ rhs: CoinTransaction
  ) -> Bool {
    if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
    return lhs.header.recordID < rhs.header.recordID
  }

  private static func validateCanonicalTransactions(
    _ transactions: [CoinTransaction],
    in profile: RuntimeProfile
  ) -> MoriDomainRejection? {
    var acceptedByID: [CoinTransactionID: CoinTransaction] = [:]
    var rewardedSettlements: Set<TaskSettlementID> = []
    var reversedTransactions: Set<CoinTransactionID> = []
    var balance = 0

    for transaction in transactions {
      if let rejection = transaction.validate(in: profile) {
        return rejection
      }
      guard acceptedByID[transaction.header.recordID] == nil else {
        return .conflictingDuplicate
      }
      switch transaction.reason {
      case .taskReward(let settlementID):
        guard rewardedSettlements.insert(settlementID).inserted else {
          return .conflictingDuplicate
        }
      case .reversal(let originalID):
        guard
          let original = acceptedByID[originalID],
          original.amount == transaction.amount,
          original.direction != .neutral,
          original.direction != transaction.direction,
          original.reason.isReversible,
          reversedTransactions.insert(originalID).inserted
        else {
          return .invalidRecord
        }
      case .cosmeticPurchase, .migration:
        break
      }

      let delta: Int
      switch transaction.direction {
      case .credit:
        delta = transaction.amount
      case .debit:
        delta = -transaction.amount
      case .neutral:
        delta = 0
      }
      let next = balance.addingReportingOverflow(delta)
      guard next.overflow == false else { return .invalidRecord }
      guard next.partialValue >= 0 else { return .insufficientCoins }
      balance = next.partialValue
      acceptedByID[transaction.header.recordID] = transaction
    }
    return nil
  }
}

extension CoinTransactionReason {
  fileprivate var isReversible: Bool {
    switch self {
    case .taskReward:
      true
    case .cosmeticPurchase, .reversal, .migration:
      false
    }
  }
}
