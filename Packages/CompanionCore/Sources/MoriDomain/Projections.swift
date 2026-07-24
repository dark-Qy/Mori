import Foundation

public struct WatchHomeProjection: Hashable, Codable, Sendable {
  public let identity: MoriIdentity
  public let pendingGlance: PassiveCompanionEvent?
  public let stepTotal: Int?
  public let sleepDuration: TimeInterval?

  public init(
    identity: MoriIdentity,
    pendingGlance: PassiveCompanionEvent?,
    stepTotal: Int?,
    sleepDuration: TimeInterval?
  ) {
    self.identity = identity
    self.pendingGlance = pendingGlance
    self.stepTotal = stepTotal
    self.sleepDuration = sleepDuration
  }
}

public struct TodayProjection: Hashable, Codable, Sendable {
  public let recommended: TaskInstance?
  public let secondary: [TaskInstance]

  public init(recommended: TaskInstance?, secondary: [TaskInstance]) {
    self.recommended = recommended
    self.secondary = secondary
  }
}

public enum DailyMemoryProjection: Hashable, Codable, Sendable {
  case preparing
  case unavailable
  case available(MemoryRecord)
}

public struct MemoriesProjection: Hashable, Codable, Sendable {
  public let records: [MemoryRecord]

  public init(records: [MemoryRecord]) {
    self.records = records
  }
}

public struct LetterInboxProjection: Hashable, Codable, Sendable {
  public let unread: [LetterRecord]
  public let read: [LetterRecord]

  public init(unread: [LetterRecord], read: [LetterRecord]) {
    self.unread = unread
    self.read = read
  }
}

public struct CollectionProjection: Hashable, Codable, Sendable {
  public let coinBalance: Int
  public let ownership: [CollectionOwnershipRecord]
  public let equipped: [CosmeticSlot: EquippedCosmetic]

  public init(
    coinBalance: Int,
    ownership: [CollectionOwnershipRecord],
    equipped: [CosmeticSlot: EquippedCosmetic]
  ) {
    self.coinBalance = coinBalance
    self.ownership = ownership
    self.equipped = equipped
  }
}

public struct ChatContextProjection: Hashable, Codable, Sendable {
  public let identity: MoriIdentity
  public let tone: MoriTone
  public let approvedEventIDs: [EventID]
  public let sealedMemoryIDs: [MemoryID]
  public let recentMessages: [ConversationRecord]

  public init(
    identity: MoriIdentity,
    tone: MoriTone,
    approvedEventIDs: [EventID],
    sealedMemoryIDs: [MemoryID],
    recentMessages: [ConversationRecord]
  ) {
    self.identity = identity
    self.tone = tone
    self.approvedEventIDs = approvedEventIDs
    self.sealedMemoryIDs = sealedMemoryIDs
    self.recentMessages = recentMessages
  }
}

public enum ProfileQueries {
  public static func watchHome(
    from state: ProfileState,
    at now: Date
  ) -> WatchHomeProjection {
    let pending = state.passiveEvents
      .filter { event in
        guard event.permitsVisibleClaim, case .pending = event.reminderState else {
          return false
        }
        return event.presentationDeadline.map { now <= $0 } ?? false
      }
      .sorted(by: eventSort)
      .last

    let stepTotal = latestFact(in: state, at: now) { value in
      if case .stepTotal(let total) = value { return total }
      return nil
    }
    let sleepDuration = latestFact(in: state, at: now) { value in
      if case .sleepDuration(let duration) = value { return duration }
      return nil
    }
    return WatchHomeProjection(
      identity: state.selectedIdentity,
      pendingGlance: pending,
      stepTotal: stepTotal,
      sleepDuration: sleepDuration
    )
  }

  public static func watchToday(
    from state: ProfileState,
    at now: Date
  ) -> TodayProjection {
    today(from: state, at: now, secondaryLimit: 2)
  }

  public static func phoneToday(
    from state: ProfileState,
    at now: Date
  ) -> TodayProjection {
    today(from: state, at: now, secondaryLimit: 3)
  }

  public static func dailyMemory(
    from state: ProfileState,
    localDay: LocalDay,
    timeZoneIdentifier: String,
    afterAvailabilityTime: Bool
  ) -> DailyMemoryProjection {
    let id = MemoryID.daily(
      profileID: state.runtimeProfile.id,
      profileEpoch: state.runtimeProfile.epoch,
      localDay: localDay,
      timeZoneIdentifier: timeZoneIdentifier
    )
    guard let memory = state.memories.first(where: { $0.header.recordID == id }) else {
      return afterAvailabilityTime ? .preparing : .unavailable
    }
    guard memory.lifecycle.isDeleted == false, memory.lifecycle.isSealed else {
      return .unavailable
    }
    return .available(memory)
  }

  public static func memories(from state: ProfileState) -> MemoriesProjection {
    MemoriesProjection(
      records: state.memories
        .filter { $0.lifecycle.isSealed && $0.lifecycle.isDeleted == false }
        .sorted {
          if $0.localDay != $1.localDay { return $0.localDay > $1.localDay }
          return $0.header.recordID < $1.header.recordID
        }
    )
  }

  public static func letters(from state: ProfileState) -> LetterInboxProjection {
    let visible = state.letters
      .filter { $0.isDeleted == false }
      .sorted {
        if $0.deliveredAt != $1.deliveredAt { return $0.deliveredAt > $1.deliveredAt }
        return $0.header.recordID < $1.header.recordID
      }
    return LetterInboxProjection(
      unread: visible.filter { $0.isRead == false },
      read: visible.filter(\.isRead)
    )
  }

  public static func collection(from state: ProfileState) -> CollectionProjection {
    CollectionProjection(
      coinBalance: state.coinLedger.balance,
      ownership: state.collection.ownership,
      equipped: state.collection.equipped
    )
  }

  public static func chatContext(
    from state: ProfileState,
    recentMessageLimit: Int = 12
  ) -> ChatContextProjection {
    let events = state.passiveEvents
      .filter(\.permitsVisibleClaim)
      .sorted(by: eventSort)
      .map(\.header.recordID)
    let memories = state.memories
      .filter { $0.lifecycle.isSealed && $0.lifecycle.isDeleted == false }
      .sorted {
        if $0.localDay != $1.localDay { return $0.localDay < $1.localDay }
        return $0.header.recordID < $1.header.recordID
      }
      .map(\.header.recordID)
    let messages = state.conversation
      .filter { $0.isDeleted == false }
      .suffix(max(0, recentMessageLimit))
    return ChatContextProjection(
      identity: state.selectedIdentity,
      tone: state.tone,
      approvedEventIDs: events,
      sealedMemoryIDs: memories,
      recentMessages: Array(messages)
    )
  }

  private static func today(
    from state: ProfileState,
    at now: Date,
    secondaryLimit: Int
  ) -> TodayProjection {
    let active = state.tasks
      .filter { task in
        guard case .active = task.lifecycle else { return false }
        return task.expiresAt.map { now <= $0 } ?? true
      }
      .sorted {
        if $0.recommendationPriority != $1.recommendationPriority {
          return $0.recommendationPriority > $1.recommendationPriority
        }
        if $0.issuedRevision != $1.issuedRevision {
          return $0.issuedRevision > $1.issuedRevision
        }
        return $0.header.recordID < $1.header.recordID
      }
    return TodayProjection(
      recommended: active.first,
      secondary: Array(active.dropFirst().prefix(max(0, secondaryLimit)))
    )
  }

  private static func eventSort(_ lhs: PassiveCompanionEvent, _ rhs: PassiveCompanionEvent)
    -> Bool
  {
    if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
    return lhs.header.recordID < rhs.header.recordID
  }

  private static func latestFact<Value>(
    in state: ProfileState,
    at now: Date,
    value: (DerivedFactValue) -> Value?
  ) -> Value? {
    state.derivedFacts
      .filter { $0.isUsable(at: now, in: state.runtimeProfile) }
      .sorted {
        if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
        return $0.header.recordID < $1.header.recordID
      }
      .compactMap { value($0.value) }
      .first
  }
}
