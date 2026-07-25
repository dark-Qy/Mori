import Foundation

public enum ExperienceEventType: String, CaseIterable, Hashable, Codable, Sendable {
  case derivedFact
  case passiveEvent
  case reminderPresented
  case reminderExpired
  case reminderReplaced
  case taskIssued
  case taskCompleted
  case taskExpired
  case coinEarned
  case coinWelcomeGranted
  case coinReversed
  case coinMigrationMarker
  case memorySealed
  case memoryDeleted
  case letterDelivered
  case letterRead
  case letterDeleted
  case identitySelected
  case cosmeticPurchased
  case cosmeticOwned
  case cosmeticEquipped
}

public enum ExperiencePrivacyClass: String, CaseIterable, Hashable, Codable, Sendable {
  case approvedDerived
  case productState
  case referenceOnly
}

public enum ExperienceTombstoneReason: String, CaseIterable, Hashable, Codable, Sendable {
  case userDeleted
  case supersededProfileEpoch
  case globalDeletion
}

public struct ExperienceTombstone: Hashable, Codable, Sendable {
  public let targetRecordID: String
  public let reason: ExperienceTombstoneReason

  public init(targetRecordID: String, reason: ExperienceTombstoneReason) {
    self.targetRecordID = targetRecordID
    self.reason = reason
  }
}

public enum ExperienceSyncPayload: Hashable, Codable, Sendable {
  case derivedFact(DerivedFactRecord)
  case passiveEvent(PassiveCompanionEvent)
  case passiveEventTransition(PassiveEventTransition)
  case task(TaskInstance)
  case taskTransition(TaskTransition)
  case coinTransaction(CoinTransaction)
  case memory(MemoryRecord)
  case memoryTransition(MemoryTransition)
  case letter(LetterRecord)
  case letterTransition(LetterTransition)
  case identitySelection(IdentitySelectionRecord)
  case collectionPurchase(CollectionPurchaseRecord)
  case collectionOwnership(CollectionOwnershipRecord)
  case collectionTransition(CollectionTransition)

  public var eventType: ExperienceEventType {
    switch self {
    case .derivedFact:
      return .derivedFact
    case .passiveEvent:
      return .passiveEvent
    case .passiveEventTransition(let transition):
      switch transition.state {
      case .pending: return .passiveEvent
      case .presented: return .reminderPresented
      case .expired: return .reminderExpired
      case .replaced: return .reminderReplaced
      }
    case .task(let task):
      switch task.lifecycle {
      case .active: return .taskIssued
      case .completed: return .taskCompleted
      case .expired: return .taskExpired
      }
    case .taskTransition(let transition):
      switch transition.state {
      case .active: return .taskIssued
      case .completed: return .taskCompleted
      case .expired: return .taskExpired
      }
    case .coinTransaction(let transaction):
      switch transaction.reason {
      case .taskReward: return .coinEarned
      case .welcomeGrant: return .coinWelcomeGranted
      case .cosmeticPurchase: return .cosmeticPurchased
      case .reversal: return .coinReversed
      case .migration: return .coinMigrationMarker
      }
    case .memory:
      return .memorySealed
    case .memoryTransition(let transition):
      switch transition.kind {
      case .seal: return .memorySealed
      case .delete: return .memoryDeleted
      }
    case .letter:
      return .letterDelivered
    case .letterTransition(let transition):
      switch transition.kind {
      case .read: return .letterRead
      case .delete: return .letterDeleted
      }
    case .identitySelection:
      return .identitySelected
    case .collectionPurchase:
      return .cosmeticPurchased
    case .collectionOwnership:
      return .cosmeticOwned
    case .collectionTransition:
      return .cosmeticEquipped
    }
  }

  public var expectedPrivacyClass: ExperiencePrivacyClass {
    switch self {
    case .derivedFact, .passiveEvent:
      return .approvedDerived
    case .memory, .memoryTransition:
      return .referenceOnly
    default:
      return .productState
    }
  }

  public var requiresTombstone: Bool {
    switch self {
    case .memoryTransition(let transition):
      if case .delete = transition.kind { true } else { false }
    case .letterTransition(let transition):
      if case .delete = transition.kind { true } else { false }
    default: false
    }
  }

  public var aggregateRecordID: String {
    switch self {
    case .derivedFact(let record): record.header.recordID.rawValue
    case .passiveEvent(let record): record.header.recordID.rawValue
    case .passiveEventTransition(let record): record.eventID.rawValue
    case .task(let record): record.header.recordID.rawValue
    case .taskTransition(let record): record.taskID.rawValue
    case .coinTransaction(let record): record.header.recordID.rawValue
    case .memory(let record): record.header.recordID.rawValue
    case .memoryTransition(let record): record.memoryID.rawValue
    case .letter(let record): record.header.recordID.rawValue
    case .letterTransition(let record): record.letterID.rawValue
    case .identitySelection(let record): record.header.recordID.rawValue
    case .collectionPurchase(let record): record.ownership.header.recordID.rawValue
    case .collectionOwnership(let record): record.header.recordID.rawValue
    case .collectionTransition(let record): record.cosmeticID.rawValue
    }
  }

  fileprivate var scope:
    (
      profileID: ProfileID,
      profileEpoch: ProfileEpoch,
      deletionEpoch: DeletionEpoch,
      schemaVersion: UInt16
    )
  {
    switch self {
    case .derivedFact(let record):
      (
        record.header.profileID, record.header.profileEpoch, record.header.deletionEpoch,
        record.header.schemaVersion
      )
    case .passiveEvent(let record):
      (
        record.header.profileID, record.header.profileEpoch, record.header.deletionEpoch,
        record.header.schemaVersion
      )
    case .passiveEventTransition(let record):
      (
        record.header.profileID, record.header.profileEpoch, record.header.deletionEpoch,
        record.header.schemaVersion
      )
    case .task(let record):
      (
        record.header.profileID, record.header.profileEpoch, record.header.deletionEpoch,
        record.header.schemaVersion
      )
    case .taskTransition(let record):
      (
        record.header.profileID, record.header.profileEpoch, record.header.deletionEpoch,
        record.header.schemaVersion
      )
    case .coinTransaction(let record):
      (
        record.header.profileID, record.header.profileEpoch, record.header.deletionEpoch,
        record.header.schemaVersion
      )
    case .memory(let record):
      (
        record.header.profileID, record.header.profileEpoch, record.header.deletionEpoch,
        record.header.schemaVersion
      )
    case .memoryTransition(let record):
      (
        record.header.profileID, record.header.profileEpoch, record.header.deletionEpoch,
        record.header.schemaVersion
      )
    case .letter(let record):
      (
        record.header.profileID, record.header.profileEpoch, record.header.deletionEpoch,
        record.header.schemaVersion
      )
    case .letterTransition(let record):
      (
        record.header.profileID, record.header.profileEpoch, record.header.deletionEpoch,
        record.header.schemaVersion
      )
    case .identitySelection(let record):
      (
        record.header.profileID, record.header.profileEpoch, record.header.deletionEpoch,
        record.header.schemaVersion
      )
    case .collectionPurchase(let record):
      (
        record.ownership.header.profileID, record.ownership.header.profileEpoch,
        record.ownership.header.deletionEpoch, record.ownership.header.schemaVersion
      )
    case .collectionOwnership(let record):
      (
        record.header.profileID, record.header.profileEpoch, record.header.deletionEpoch,
        record.header.schemaVersion
      )
    case .collectionTransition(let record):
      (
        record.header.profileID, record.header.profileEpoch, record.header.deletionEpoch,
        record.header.schemaVersion
      )
    }
  }

  fileprivate var expectedSourceEventID: EventID? {
    switch self {
    case .task(let task): task.sourceEventID
    case .letter(let letter):
      if case .event(let eventID) = letter.source { eventID } else { nil }
    default: nil
    }
  }

  fileprivate var expectedSettlementID: TaskSettlementID? {
    switch self {
    case .task(let task): task.settlementID
    case .taskTransition(let transition): transition.settlementID
    case .coinTransaction(let transaction):
      if case .taskReward(let settlementID) = transaction.reason { settlementID } else { nil }
    default: nil
    }
  }

  fileprivate func validateShape(in profile: RuntimeProfile) -> MoriDomainRejection? {
    switch self {
    case .derivedFact(let record):
      return record.validate(in: profile)
    case .passiveEvent(let event):
      guard case .pending = event.reminderState else { return .invalidPayload }
      return event.validate(in: profile, sensingEpoch: event.sensingEpoch)
    case .passiveEventTransition(let transition):
      guard transition.header.scopeMatches(profile), transition.revision.isValid else {
        return .invalidRecord
      }
      guard case .pending = transition.state else { break }
      return .invalidPayload
    case .task(let task):
      guard case .active = task.lifecycle else { return .invalidPayload }
      return task.validate(in: profile)
    case .taskTransition(let transition):
      guard transition.header.scopeMatches(profile), transition.revision.isValid else {
        return .invalidRecord
      }
      switch transition.state {
      case .active:
        return .invalidPayload
      case .completed:
        guard transition.settlementID != nil else { return .invalidPayload }
      case .expired:
        guard transition.settlementID == nil else { return .invalidPayload }
      }
    case .coinTransaction(let transaction):
      if case .cosmeticPurchase = transaction.reason {
        return .invalidPayload
      }
      return transaction.validate(in: profile)
    case .memory(let memory):
      guard
        memory.lifecycle.isSealed,
        memory.winningTransitionID == nil
      else {
        return .invalidPayload
      }
      return memory.validate(in: profile)
    case .memoryTransition(let transition):
      guard transition.header.scopeMatches(profile), transition.revision.isValid else {
        return .invalidRecord
      }
      guard case .delete = transition.kind else { return .invalidPayload }
    case .letter(let letter):
      guard letter.isRead == false, letter.isDeleted == false else {
        return .invalidPayload
      }
      return letter.validate(in: profile)
    case .letterTransition(let transition):
      guard
        transition.header.scopeMatches(profile),
        transition.header.recordID.isValid,
        transition.letterID.isValid,
        transition.revision.isValid
      else {
        return .invalidRecord
      }
    case .identitySelection(let selection):
      guard
        selection.header.scopeMatches(profile),
        selection.header.recordID.isValid,
        selection.revision.isValid
      else {
        return .invalidRecord
      }
    case .collectionPurchase(let purchase):
      return purchase.validate(in: profile)
    case .collectionOwnership(let ownership):
      guard
        ownership.header.scopeMatches(profile),
        ownership.header.recordID.isValid,
        ownership.cosmeticID.isValid,
        ownership.purchaseTransactionID == nil,
        ownership.revision.isValid
      else {
        return .invalidRecord
      }
    case .collectionTransition(let transition):
      guard
        transition.header.scopeMatches(profile),
        transition.header.recordID.isValid,
        transition.cosmeticID.isValid,
        transition.revision.isValid
      else {
        return .invalidRecord
      }
    }
    return nil
  }
}

public struct ExperienceSyncEnvelope: Hashable, Codable, Sendable {
  public let schemaVersion: UInt16
  public let eventID: ExperienceEventID
  public let eventType: ExperienceEventType
  public let profileID: ProfileID
  public let profileEpoch: ProfileEpoch
  public let deletionEpoch: DeletionEpoch
  public let profileSource: RuntimeProfileSource
  public let originDeviceID: String
  public let originSequence: UInt64
  public let revision: LamportRevision
  public let observedAt: Date?
  public let authoredAt: Date
  public let privacyClass: ExperiencePrivacyClass
  public let tombstone: ExperienceTombstone?
  public let sourceEventID: EventID?
  public let settlementID: TaskSettlementID?
  public let payload: ExperienceSyncPayload

  public init(
    schemaVersion: UInt16 = 1,
    eventID: ExperienceEventID,
    eventType: ExperienceEventType,
    profileID: ProfileID,
    profileEpoch: ProfileEpoch,
    deletionEpoch: DeletionEpoch,
    profileSource: RuntimeProfileSource = .real,
    originDeviceID: String,
    originSequence: UInt64,
    revision: LamportRevision,
    observedAt: Date?,
    authoredAt: Date,
    privacyClass: ExperiencePrivacyClass,
    tombstone: ExperienceTombstone?,
    sourceEventID: EventID?,
    settlementID: TaskSettlementID?,
    payload: ExperienceSyncPayload
  ) {
    self.schemaVersion = schemaVersion
    self.eventID = eventID
    self.eventType = eventType
    self.profileID = profileID
    self.profileEpoch = profileEpoch
    self.deletionEpoch = deletionEpoch
    self.profileSource = profileSource
    self.originDeviceID = originDeviceID
    self.originSequence = originSequence
    self.revision = revision
    self.observedAt = observedAt
    self.authoredAt = authoredAt
    self.privacyClass = privacyClass
    self.tombstone = tombstone
    self.sourceEventID = sourceEventID
    self.settlementID = settlementID
    self.payload = payload
  }

  public func validate() -> MoriDomainRejection? {
    guard schemaVersion == 1, payload.scope.schemaVersion == 1 else {
      return .invalidSchema
    }
    guard
      eventID.isValid,
      profileID.isValid,
      profileEpoch.isValid,
      deletionEpoch.isValid,
      originSequence > 0,
      revision.isValid,
      originDeviceID.isEmpty == false,
      revision.originDeviceID == originDeviceID
    else {
      return .invalidIdentifier
    }
    let payloadProfile = RuntimeProfile(
      id: profileID,
      epoch: profileEpoch,
      deletionEpoch: deletionEpoch,
      source: profileSource
    )
    guard payloadProfile.isValid else { return .profileMismatch }
    guard eventType == payload.eventType else { return .invalidPayload }
    guard privacyClass == payload.expectedPrivacyClass else { return .invalidPayload }
    guard
      profileID == payload.scope.profileID,
      profileEpoch == payload.scope.profileEpoch,
      deletionEpoch == payload.scope.deletionEpoch
    else {
      return .profileMismatch
    }
    if let rejection = payload.validateShape(in: payloadProfile) {
      return rejection
    }
    guard sourceEventID == payload.expectedSourceEventID else {
      return .invalidPayload
    }
    guard settlementID == payload.expectedSettlementID else {
      return .invalidPayload
    }
    guard payload.requiresTombstone == (tombstone != nil) else {
      return .tombstoneMismatch
    }
    if let tombstone {
      guard
        tombstone.targetRecordID.isEmpty == false,
        tombstone.targetRecordID == payload.aggregateRecordID
      else {
        return .tombstoneMismatch
      }
    }
    return nil
  }
}
