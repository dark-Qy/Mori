import Foundation

public struct ProfileState: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<ProfileID>
  public let runtimeProfile: RuntimeProfile
  public internal(set) var companionSensingEnabled: Bool
  public internal(set) var currentSensingEpoch: SensingEpoch
  public internal(set) var selectedIdentity: MoriIdentity
  public internal(set) var identityRevision: LamportRevision
  public internal(set) var tone: MoriTone
  public internal(set) var derivedFacts: [DerivedFactRecord]
  public internal(set) var passiveEvents: [PassiveCompanionEvent]
  public internal(set) var tasks: [TaskInstance]
  public internal(set) var cooldowns: [TaskCooldownRecord]
  public internal(set) var coinLedger: CoinLedger
  public internal(set) var collection: CollectionState
  public internal(set) var memories: [MemoryRecord]
  public internal(set) var letters: [LetterRecord]
  public internal(set) var conversation: [ConversationRecord]
  public internal(set) var experienceLedger: [ExperienceSyncEnvelope]

  public init(
    header: ProfileScopedRecordHeader<ProfileID>,
    runtimeProfile: RuntimeProfile,
    companionSensingEnabled: Bool,
    currentSensingEpoch: SensingEpoch,
    selectedIdentity: MoriIdentity,
    identityRevision: LamportRevision,
    tone: MoriTone = .gentle,
    derivedFacts: [DerivedFactRecord] = [],
    passiveEvents: [PassiveCompanionEvent] = [],
    tasks: [TaskInstance] = [],
    cooldowns: [TaskCooldownRecord] = [],
    coinLedger: CoinLedger,
    collection: CollectionState,
    memories: [MemoryRecord] = [],
    letters: [LetterRecord] = [],
    conversation: [ConversationRecord] = [],
    experienceLedger: [ExperienceSyncEnvelope] = []
  ) {
    self.header = header
    self.runtimeProfile = runtimeProfile
    self.companionSensingEnabled = companionSensingEnabled
    self.currentSensingEpoch = currentSensingEpoch
    self.selectedIdentity = selectedIdentity
    self.identityRevision = identityRevision
    self.tone = tone
    self.derivedFacts = derivedFacts
    self.passiveEvents = passiveEvents
    self.tasks = tasks
    self.cooldowns = cooldowns
    self.coinLedger = coinLedger
    self.collection = collection
    self.memories = memories
    self.letters = letters
    self.conversation = conversation
    self.experienceLedger = experienceLedger
  }

  public func validate() -> MoriDomainRejection? {
    guard runtimeProfile.isValid, currentSensingEpoch.isValid, identityRevision.isValid else {
      return .invalidRecord
    }
    guard
      header.schemaVersion == 1,
      header.recordID == runtimeProfile.id,
      header.scopeMatches(runtimeProfile),
      coinLedger.header.scopeMatches(runtimeProfile),
      collection.header.scopeMatches(runtimeProfile)
    else {
      return .profileMismatch
    }
    if let rejection = coinLedger.validate(in: runtimeProfile) {
      return rejection
    }
    if let rejection = collection.validate(in: runtimeProfile, coinLedger: coinLedger) {
      return rejection
    }

    var factIDs: Set<EvidenceID> = []
    for fact in derivedFacts {
      if let rejection = fact.validate(in: runtimeProfile) {
        return rejection
      }
      guard factIDs.insert(fact.header.recordID).inserted else {
        return .conflictingDuplicate
      }
      if case .companion(let sensingEpoch) = fact.authorization {
        guard sensingEpoch <= currentSensingEpoch else {
          return .sensingEpochMismatch
        }
      }
    }

    var passiveEventIDs: Set<EventID> = []
    for event in passiveEvents {
      if let rejection = event.validate(
        in: runtimeProfile,
        sensingEpoch: event.sensingEpoch
      ) {
        return rejection
      }
      guard
        passiveEventIDs.insert(event.header.recordID).inserted,
        event.sensingEpoch <= currentSensingEpoch,
        event.sensingEpoch == currentSensingEpoch || event.reminderState.isTerminal,
        event.evidence.allSatisfy({ reference in
          derivedFacts.contains {
            $0.header.recordID == reference.id
              && $0.value.kind == reference.kind
              && $0.authorizesCompanionUse(in: event.sensingEpoch)
              && $0.isUsable(at: event.observedAt, in: runtimeProfile)
          }
        })
      else {
        return .invalidRecord
      }
    }

    var taskIDs: Set<TaskID> = []
    var taskSourceIDs: Set<EventID> = []
    for task in tasks {
      if let rejection = task.validate(in: runtimeProfile) {
        return rejection
      }
      guard
        taskIDs.insert(task.header.recordID).inserted,
        taskSourceIDs.insert(task.sourceEventID).inserted,
        passiveEventIDs.contains(task.sourceEventID),
        task.lifecycle.isTerminal == (task.winningTransitionID != nil)
      else {
        return .invalidRecord
      }
    }

    var cooldownIDs: Set<TaskCooldownID> = []
    for cooldown in cooldowns {
      guard
        cooldown.header.schemaVersion == 1,
        cooldown.header.scopeMatches(runtimeProfile),
        cooldown.header.recordID.isValid,
        cooldown.key.isValid,
        cooldown.duration >= 0,
        cooldown.duration.isFinite,
        cooldown.revision.isValid,
        cooldownIDs.insert(cooldown.header.recordID).inserted,
        tasks.contains(where: {
          $0.cooldownKey == cooldown.key
            && $0.issuedAt == cooldown.issuedAt
            && $0.cooldownDuration == cooldown.duration
            && $0.issuedRevision == cooldown.revision
        })
      else {
        return .invalidRecord
      }
    }
    guard
      tasks.allSatisfy({ task in
        cooldowns.contains {
          $0.key == task.cooldownKey
            && $0.issuedAt == task.issuedAt
            && $0.revision == task.issuedRevision
        }
      })
    else {
      return .invalidRecord
    }

    var memoryIDs: Set<MemoryID> = []
    for memory in memories {
      if let rejection = memory.validate(in: runtimeProfile) {
        return rejection
      }
      guard memoryIDs.insert(memory.header.recordID).inserted else {
        return .conflictingDuplicate
      }
      if case .sealed(let content) = memory.lifecycle {
        guard
          content.facts.allSatisfy({ reference in
            guard
              let event = passiveEvents.first(where: {
                $0.header.recordID == reference.sourceEventID
              }),
              event.memoryEligibility == .eligible,
              event.evidence.contains(where: {
                $0.id == reference.evidenceID && $0.kind == reference.kind
              })
            else {
              return false
            }
            return derivedFacts.contains {
              $0.header.recordID == reference.evidenceID
                && $0.value.kind == reference.kind
                && $0.authorizesCompanionUse(in: event.sensingEpoch)
            }
          })
        else {
          return .invalidRecord
        }
      }
    }

    var letterIDs: Set<LetterID> = []
    for letter in letters {
      if let rejection = letter.validate(in: runtimeProfile) {
        return rejection
      }
      guard letterIDs.insert(letter.header.recordID).inserted else {
        return .conflictingDuplicate
      }
      switch letter.source {
      case .event(let eventID):
        guard passiveEventIDs.contains(eventID) else { return .invalidRecord }
      case .memory(let memoryID):
        guard memoryIDs.contains(memoryID) else { return .invalidRecord }
      }
    }

    var conversationRecordIDs: Set<ConversationRecordID> = []
    for record in conversation {
      if let rejection = record.validate(in: runtimeProfile) {
        return rejection
      }
      guard
        conversationRecordIDs.insert(record.header.recordID).inserted,
        record.referencedMemoryIDs.allSatisfy(memoryIDs.contains)
      else {
        return .invalidRecord
      }
    }

    var experienceEventIDs: Set<ExperienceEventID> = []
    for envelope in experienceLedger {
      if let rejection = envelope.validate() {
        return rejection
      }
      guard
        envelope.profileID == runtimeProfile.id,
        envelope.profileEpoch == runtimeProfile.epoch,
        envelope.deletionEpoch == runtimeProfile.deletionEpoch,
        envelope.profileSource == runtimeProfile.source,
        experienceEventIDs.insert(envelope.eventID).inserted
      else {
        return .profileMismatch
      }
    }
    guard coinLedger.balance >= 0 else { return .insufficientCoins }
    return nil
  }

  public mutating func advanceSensingEpoch(
    to epoch: SensingEpoch,
    effectiveAt: Date
  ) -> MutationResult {
    setCompanionSensing(
      enabled: companionSensingEnabled,
      epoch: epoch,
      effectiveAt: effectiveAt
    )
  }

  public mutating func setCompanionSensing(
    enabled: Bool,
    epoch: SensingEpoch,
    effectiveAt: Date
  ) -> MutationResult {
    guard epoch.isValid else { return .rejected(.invalidIdentifier) }
    guard epoch > currentSensingEpoch else {
      return epoch == currentSensingEpoch && enabled == companionSensingEnabled
        ? .duplicate
        : .rejected(.sensingEpochMismatch)
    }
    companionSensingEnabled = enabled
    currentSensingEpoch = epoch
    for index in passiveEvents.indices {
      guard passiveEvents[index].sensingEpoch < epoch else { continue }
      guard case .pending = passiveEvents[index].reminderState else { continue }
      _ = passiveEvents[index].expireForSupersededSensingEpoch(
        epoch,
        at: effectiveAt
      )
    }
    return .applied
  }
}

public enum ProfileMutation: Sendable {
  case derivedFact(DerivedFactRecord)
  case passiveEvent(PassiveCompanionEvent)
  case passiveEventTransition(PassiveEventTransition)
  case task(TaskInstance, manualTaskHasVisibleSlot: Bool)
  case taskTransition(TaskTransition)
  case coinTransaction(CoinTransaction)
  case memory(MemoryRecord)
  case memoryTransition(MemoryTransition)
  case letter(LetterRecord)
  case letterTransition(LetterTransition)
  case identitySelection(IdentitySelectionRecord)
  case collectionOwnership(CollectionOwnershipRecord)
  case collectionTransition(CollectionTransition)
  case purchase(
    item: CosmeticCatalogItem,
    ownership: CollectionOwnershipRecord,
    transaction: CoinTransaction
  )
  case conversation(ConversationRecord)
  case conversationTransition(ConversationTransition)
}

public enum ProfileReducer {
  public static func apply(
    _ mutation: ProfileMutation,
    to state: inout ProfileState
  ) -> MutationResult {
    guard state.validate() == nil else { return .rejected(.invalidRecord) }
    switch mutation {
    case .derivedFact(let record):
      return insertFact(record, into: &state)
    case .passiveEvent(let event):
      return insertPassiveEvent(event, into: &state)
    case .passiveEventTransition(let transition):
      return applyPassiveTransition(transition, to: &state)
    case .task(let task, let visible):
      return issueTask(task, manualTaskHasVisibleSlot: visible, into: &state)
    case .taskTransition(let transition):
      return applyTaskTransition(transition, to: &state)
    case .coinTransaction(let transaction):
      return applyCoin(transaction, to: &state)
    case .memory(let memory):
      return insertMemory(memory, into: &state)
    case .memoryTransition(let transition):
      return applyMemoryTransition(transition, to: &state)
    case .letter(let letter):
      return mergeLetter(letter, into: &state)
    case .letterTransition(let transition):
      return applyLetterTransition(transition, to: &state)
    case .identitySelection(let selection):
      return applyIdentity(selection, to: &state)
    case .collectionOwnership(let ownership):
      return applyCollectionOwnership(ownership, to: &state)
    case .collectionTransition(let transition):
      return state.collection.equip(transition, in: state.runtimeProfile)
    case .purchase(let item, let ownership, let transaction):
      switch CollectionReducer.purchase(
        item: item,
        ownership: ownership,
        transaction: transaction,
        collection: state.collection,
        coinLedger: state.coinLedger,
        profile: state.runtimeProfile
      ) {
      case .purchased(let result):
        state.collection = result.collection
        state.coinLedger = result.coinLedger
        return .applied
      case .duplicate:
        return .duplicate
      case .rejected(let reason):
        return .rejected(reason)
      }
    case .conversation(let record):
      return insertConversation(record, into: &state)
    case .conversationTransition(let transition):
      return applyConversationTransition(transition, to: &state)
    }
  }

  public static func apply(
    _ envelope: ExperienceSyncEnvelope,
    to state: inout ProfileState
  ) -> MutationResult {
    if let existing = state.experienceLedger.first(where: { $0.eventID == envelope.eventID }) {
      return existing == envelope ? .duplicate : .rejected(.conflictingDuplicate)
    }
    if let rejection = envelope.validate() { return .rejected(rejection) }
    guard envelope.profileID == state.runtimeProfile.id else {
      return .rejected(.profileMismatch)
    }
    guard envelope.profileSource == state.runtimeProfile.source else {
      return .rejected(.profileMismatch)
    }
    guard envelope.profileEpoch == state.runtimeProfile.epoch else {
      return .rejected(.profileEpochMismatch)
    }
    guard envelope.deletionEpoch == state.runtimeProfile.deletionEpoch else {
      return .rejected(.deletionEpochMismatch)
    }

    let result: MutationResult
    switch envelope.payload {
    case .derivedFact(let record):
      result = apply(.derivedFact(record), to: &state)
    case .passiveEvent(let event):
      guard case .pending = event.reminderState else {
        return .rejected(.invalidPayload)
      }
      result = apply(.passiveEvent(event), to: &state)
    case .passiveEventTransition(let transition):
      result = apply(.passiveEventTransition(transition), to: &state)
    case .task(let task):
      guard case .active = task.lifecycle else { return .rejected(.invalidPayload) }
      result = apply(.task(task, manualTaskHasVisibleSlot: true), to: &state)
    case .taskTransition(let transition):
      result = apply(.taskTransition(transition), to: &state)
    case .coinTransaction(let transaction):
      result = apply(.coinTransaction(transaction), to: &state)
    case .memory(let memory):
      guard memory.lifecycle.isSealed else {
        return .rejected(.invalidPayload)
      }
      result = apply(.memory(memory), to: &state)
    case .memoryTransition(let transition):
      guard case .delete = transition.kind else {
        return .rejected(.invalidPayload)
      }
      result = apply(.memoryTransition(transition), to: &state)
    case .letter(let letter):
      guard letter.isRead == false, letter.isDeleted == false else {
        return .rejected(.invalidPayload)
      }
      result = apply(.letter(letter), to: &state)
    case .letterTransition(let transition):
      result = apply(.letterTransition(transition), to: &state)
    case .identitySelection(let selection):
      result = apply(.identitySelection(selection), to: &state)
    case .collectionPurchase(let purchase):
      result = apply(
        .purchase(
          item: purchase.item,
          ownership: purchase.ownership,
          transaction: purchase.transaction
        ),
        to: &state
      )
    case .collectionOwnership(let ownership):
      result = apply(.collectionOwnership(ownership), to: &state)
    case .collectionTransition(let transition):
      result = apply(.collectionTransition(transition), to: &state)
    }
    switch result {
    case .applied, .duplicate:
      state.experienceLedger.append(envelope)
      state.experienceLedger.sort {
        if $0.revision != $1.revision { return $0.revision < $1.revision }
        return $0.eventID < $1.eventID
      }
    case .rejected:
      break
    }
    return result
  }

  private static func insertFact(
    _ record: DerivedFactRecord,
    into state: inout ProfileState
  ) -> MutationResult {
    if let rejection = record.validate(in: state.runtimeProfile) {
      return .rejected(rejection)
    }
    if case .companion(let sensingEpoch) = record.authorization {
      guard
        state.companionSensingEnabled,
        sensingEpoch == state.currentSensingEpoch
      else {
        return .rejected(.sensingEpochMismatch)
      }
    }
    if let existing = state.derivedFacts.first(where: {
      $0.header.recordID == record.header.recordID
    }) {
      return existing == record ? .duplicate : .rejected(.conflictingDuplicate)
    }
    state.derivedFacts.append(record)
    return .applied
  }

  private static func insertPassiveEvent(
    _ event: PassiveCompanionEvent,
    into state: inout ProfileState
  ) -> MutationResult {
    guard state.companionSensingEnabled else {
      return .rejected(.sensingEpochMismatch)
    }
    if let existing = state.passiveEvents.first(where: {
      $0.header.recordID == event.header.recordID
    }) {
      return existing == event ? .duplicate : .rejected(.conflictingDuplicate)
    }
    if let rejection = event.validate(
      in: state.runtimeProfile,
      sensingEpoch: state.currentSensingEpoch
    ) {
      return .rejected(rejection)
    }
    guard
      event.evidence.allSatisfy({ reference in
        state.derivedFacts.contains {
          $0.header.recordID == reference.id
            && $0.value.kind == reference.kind
            && $0.authorizesCompanionUse(in: event.sensingEpoch)
            && $0.isUsable(at: event.observedAt, in: state.runtimeProfile)
        }
      })
    else {
      return .rejected(.invalidRecord)
    }
    state.passiveEvents.append(event)
    return .applied
  }

  private static func applyPassiveTransition(
    _ transition: PassiveEventTransition,
    to state: inout ProfileState
  ) -> MutationResult {
    guard
      let index = state.passiveEvents.firstIndex(where: {
        $0.header.recordID == transition.eventID
      })
    else {
      return .rejected(.invalidRecord)
    }
    return state.passiveEvents[index].apply(transition, in: state.runtimeProfile)
  }

  private static func issueTask(
    _ task: TaskInstance,
    manualTaskHasVisibleSlot: Bool,
    into state: inout ProfileState
  ) -> MutationResult {
    guard
      let event = state.passiveEvents.first(where: {
        $0.header.recordID == task.sourceEventID
      })
    else {
      return .rejected(.invalidRecord)
    }
    let existing = state.tasks.first(where: { $0.sourceEventID == task.sourceEventID })
    let cooldown = state.cooldowns
      .filter { $0.key == task.cooldownKey }
      .max {
        if $0.revision != $1.revision { return $0.revision < $1.revision }
        return $0.header.recordID < $1.header.recordID
      }
    let decision = TaskIssuancePolicy.evaluate(
      event: event,
      candidate: task,
      existingTaskForSourceEvent: existing,
      cooldown: cooldown,
      manualTaskHasVisibleSlot: manualTaskHasVisibleSlot,
      profile: state.runtimeProfile,
      sensingEpoch: state.currentSensingEpoch
    )
    guard decision == .applied else { return decision }
    state.tasks.append(task)
    state.cooldowns.append(
      TaskCooldownRecord(
        header: ProfileScopedRecordHeader(
          recordID: TaskCooldownID(
            "cooldown:\(task.cooldownKey.rawValue):\(task.header.recordID.rawValue)"
          ),
          profileID: state.runtimeProfile.id,
          profileEpoch: state.runtimeProfile.epoch,
          deletionEpoch: state.runtimeProfile.deletionEpoch
        ),
        key: task.cooldownKey,
        issuedAt: task.issuedAt,
        duration: task.cooldownDuration,
        revision: task.issuedRevision
      )
    )
    return .applied
  }

  private static func applyTaskTransition(
    _ transition: TaskTransition,
    to state: inout ProfileState
  ) -> MutationResult {
    guard
      let index = state.tasks.firstIndex(where: {
        $0.header.recordID == transition.taskID
      })
    else {
      return .rejected(.invalidRecord)
    }
    return state.tasks[index].apply(transition, in: state.runtimeProfile)
  }

  private static func applyCoin(
    _ transaction: CoinTransaction,
    to state: inout ProfileState
  ) -> MutationResult {
    if case .taskReward(let settlementID) = transaction.reason {
      guard let task = state.tasks.first(where: { $0.settlementID == settlementID }) else {
        return .rejected(.invalidRecord)
      }
      guard task.lifecycle.isCompleted, task.rewardTier.rawValue == transaction.amount else {
        return .rejected(.completionNotAllowed)
      }
    }
    if case .cosmeticPurchase(let cosmeticID) = transaction.reason,
      state.collection.owns(cosmeticID)
    {
      return .rejected(.itemAlreadyOwned)
    }
    if case .cosmeticPurchase = transaction.reason {
      return .rejected(.invalidPayload)
    }
    return state.coinLedger.apply(transaction, in: state.runtimeProfile)
  }

  private static func insertMemory(
    _ memory: MemoryRecord,
    into state: inout ProfileState
  ) -> MutationResult {
    if let rejection = memory.validate(in: state.runtimeProfile) {
      return .rejected(rejection)
    }
    if case .sealed(let content) = memory.lifecycle {
      guard
        content.facts.allSatisfy({ reference in
          guard
            let event = state.passiveEvents.first(where: {
              $0.header.recordID == reference.sourceEventID
            }),
            event.memoryEligibility == .eligible,
            event.evidence.contains(where: {
              $0.id == reference.evidenceID && $0.kind == reference.kind
            })
          else {
            return false
          }
          return state.derivedFacts.contains {
            $0.header.recordID == reference.evidenceID
              && $0.value.kind == reference.kind
              && $0.authorizesCompanionUse(in: event.sensingEpoch)
          }
        })
      else {
        return .rejected(.invalidRecord)
      }
    }
    guard
      let index = state.memories.firstIndex(where: {
        $0.header.recordID == memory.header.recordID
      })
    else {
      state.memories.append(memory)
      return .applied
    }
    let existing = state.memories[index]
    if existing == memory { return .duplicate }
    if existing.lifecycle.isDeleted {
      // Delete wins over a late sealed snapshot of the same daily memory.
      return .duplicate
    }
    if memory.lifecycle.isDeleted {
      state.memories[index] = memory
      return .applied
    }
    // A daily memory seals once. Canonical envelope order chooses the first
    // well-formed sealed record and consumes later valid terminal losers.
    return .duplicate
  }

  private static func applyMemoryTransition(
    _ transition: MemoryTransition,
    to state: inout ProfileState
  ) -> MutationResult {
    guard
      let index = state.memories.firstIndex(where: {
        $0.header.recordID == transition.memoryID
      })
    else {
      return .rejected(.invalidRecord)
    }
    return state.memories[index].apply(transition, in: state.runtimeProfile)
  }

  private static func mergeLetter(
    _ letter: LetterRecord,
    into state: inout ProfileState
  ) -> MutationResult {
    if let rejection = letter.validate(in: state.runtimeProfile) {
      return .rejected(rejection)
    }
    let hasSource: Bool
    switch letter.source {
    case .event(let eventID):
      hasSource = state.passiveEvents.contains {
        $0.header.recordID == eventID
      }
    case .memory(let memoryID):
      hasSource = state.memories.contains {
        $0.header.recordID == memoryID
          && $0.lifecycle.isSealed
          && $0.lifecycle.isDeleted == false
      }
    }
    guard hasSource else { return .rejected(.invalidRecord) }
    guard
      let index = state.letters.firstIndex(where: {
        $0.header.recordID == letter.header.recordID
      })
    else {
      state.letters.append(letter)
      return .applied
    }
    switch state.letters[index].merged(with: letter, in: state.runtimeProfile) {
    case .merged(let merged):
      state.letters[index] = merged
      return .applied
    case .duplicate:
      return .duplicate
    case .rejected(let reason):
      return .rejected(reason)
    }
  }

  private static func applyLetterTransition(
    _ transition: LetterTransition,
    to state: inout ProfileState
  ) -> MutationResult {
    guard
      let index = state.letters.firstIndex(where: {
        $0.header.recordID == transition.letterID
      })
    else {
      return .rejected(.invalidRecord)
    }
    return state.letters[index].apply(transition, in: state.runtimeProfile)
  }

  private static func applyCollectionOwnership(
    _ ownership: CollectionOwnershipRecord,
    to state: inout ProfileState
  ) -> MutationResult {
    guard ownership.purchaseTransactionID == nil else {
      return .rejected(.invalidPayload)
    }
    return state.collection.applyOwnership(ownership, in: state.runtimeProfile)
  }

  private static func applyIdentity(
    _ selection: IdentitySelectionRecord,
    to state: inout ProfileState
  ) -> MutationResult {
    guard
      selection.header.schemaVersion == 1,
      selection.header.recordID.isValid,
      selection.revision.isValid,
      selection.header.scopeMatches(state.runtimeProfile)
    else {
      return .rejected(.invalidRecord)
    }
    guard selection.revision > state.identityRevision else {
      return selection.revision == state.identityRevision
        && selection.identity == state.selectedIdentity
        ? .duplicate
        : .rejected(.conflictingDuplicate)
    }
    state.selectedIdentity = selection.identity
    state.identityRevision = selection.revision
    return .applied
  }

  private static func insertConversation(
    _ record: ConversationRecord,
    into state: inout ProfileState
  ) -> MutationResult {
    if let rejection = record.validate(in: state.runtimeProfile) {
      return .rejected(rejection)
    }
    if let existing = state.conversation.first(where: {
      $0.header.recordID == record.header.recordID
    }) {
      return existing == record ? .duplicate : .rejected(.conflictingDuplicate)
    }
    state.conversation.append(record)
    state.conversation.sort {
      if $0.revision != $1.revision { return $0.revision < $1.revision }
      return $0.header.recordID < $1.header.recordID
    }
    return .applied
  }

  private static func applyConversationTransition(
    _ transition: ConversationTransition,
    to state: inout ProfileState
  ) -> MutationResult {
    guard
      let index = state.conversation.firstIndex(where: {
        $0.header.recordID == transition.recordID
      })
    else {
      return .rejected(.invalidRecord)
    }
    return state.conversation[index].apply(transition, in: state.runtimeProfile)
  }
}
