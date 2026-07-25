import Foundation
import MoriDomain

public enum DailyMemoryDeviceRole: String, Hashable, Codable, Sendable {
  case iPhone
  case watch
}

public enum DailyMemoryUnavailability: Hashable, Sendable {
  case beforeReleaseTime
  case watchWaitingForSync
  case companionSensingDisabled
  case noEligibleEvents
  case deleted
  case existingDraft
  case invalidProfileState(MoriDomainRejection)
}

public enum DailyMemoryCompositionOutcome: Hashable, Sendable {
  case sealed(MemoryRecord)
  case alreadySealed(MemoryRecord)
  case unavailable(DailyMemoryUnavailability)
}

/// Pure shared composition policy. Only the iPhone creates a durable record;
/// Watch may render a synchronized sealed record but never authors a fallback.
public struct DailyMemoryCompositionPolicy: Sendable {
  public static let releaseHour = 22
  public static let maximumFactCount = 12

  public init() {}

  public func compose(
    state: ProfileState,
    at date: Date,
    timeZone: TimeZone,
    deviceRole: DailyMemoryDeviceRole,
    authoredRevision: LamportRevision,
    moments: [SealedMemoryMoment] = []
  ) -> DailyMemoryCompositionOutcome {
    if let rejection = state.validate() {
      return .unavailable(.invalidProfileState(rejection))
    }

    let localDay = Self.localDay(for: date, timeZone: timeZone)
    let memoryID = MemoryID.daily(
      profileID: state.runtimeProfile.id,
      profileEpoch: state.runtimeProfile.epoch,
      localDay: localDay,
      timeZoneIdentifier: timeZone.identifier
    )
    if let existing = state.memories.first(where: {
      $0.header.recordID == memoryID
    }) {
      switch existing.lifecycle {
      case .sealed:
        return .alreadySealed(existing)
      case .deleted:
        return .unavailable(.deleted)
      case .draft:
        return .unavailable(.existingDraft)
      }
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard calendar.component(.hour, from: date) >= Self.releaseHour else {
      return .unavailable(.beforeReleaseTime)
    }
    guard deviceRole == .iPhone else {
      return .unavailable(.watchWaitingForSync)
    }
    guard state.companionSensingEnabled else {
      return .unavailable(.companionSensingDisabled)
    }

    let eligibleEvents = state.passiveEvents
      .filter {
        $0.memoryEligibility == .eligible
          && Self.localDay(for: $0.observedAt, timeZone: timeZone) == localDay
      }
      .sorted(by: Self.isEarlier)
    let facts = Self.memoryFacts(
      events: eligibleEvents,
      derivedFacts: state.derivedFacts
    )
    guard !facts.isEmpty else {
      return .unavailable(.noEligibleEvents)
    }
    let referencedEvidenceIDs = Set(facts.map(\.evidenceID))
    let referencedDerivedFacts = state.derivedFacts.filter {
      referencedEvidenceIDs.contains($0.header.recordID)
    }

    let representative = eligibleEvents.last
    let content = SealedMemoryContent(
      facts: Array(facts.prefix(Self.maximumFactCount)),
      narrative: Self.narrative(
        for: eligibleEvents,
        derivedFacts: referencedDerivedFacts
      ),
      sceneID: representative?.sceneID ?? "memory.day",
      moriActionID: representative?.moriActionID ?? "companion.remember",
      sealedAt: date,
      moments: moments
    )
    let record = MemoryRecord(
      header: ProfileScopedRecordHeader(
        recordID: memoryID,
        profileID: state.runtimeProfile.id,
        profileEpoch: state.runtimeProfile.epoch,
        deletionEpoch: state.runtimeProfile.deletionEpoch
      ),
      localDay: localDay,
      timeZoneIdentifier: timeZone.identifier,
      authoredRevision: authoredRevision,
      lifecycle: .sealed(content)
    )
    if let rejection = record.validate(in: state.runtimeProfile) {
      return .unavailable(.invalidProfileState(rejection))
    }
    return .sealed(record)
  }

  private static func memoryFacts(
    events: [PassiveCompanionEvent],
    derivedFacts: [DerivedFactRecord]
  ) -> [MemoryFactReference] {
    let factsByID = Dictionary(
      derivedFacts.map { ($0.header.recordID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var seen: Set<EvidenceID> = []
    var result: [MemoryFactReference] = []

    for event in events {
      for reference in event.evidence.sorted(by: evidenceReferenceOrder) {
        guard
          seen.insert(reference.id).inserted,
          let fact = factsByID[reference.id],
          fact.value.kind == reference.kind,
          fact.authorizesCompanionUse(in: event.sensingEpoch)
        else {
          continue
        }
        result.append(
          MemoryFactReference(
            evidenceID: reference.id,
            kind: reference.kind,
            sourceEventID: event.header.recordID
          )
        )
      }
    }
    return result
  }

  private static func narrative(
    for events: [PassiveCompanionEvent],
    derivedFacts: [DerivedFactRecord]
  ) -> String {
    let kinds = Set(events.map(\.kind))
    if kinds.contains(.pausedTogether)
      && (kinds.contains(.sharedWalk) || kinds.contains(.fastPace))
    {
      return "今天我们走过了一段路，也一起停下来歇了一会儿。"
    }
    let maximumStepTotal = derivedFacts.compactMap {
      if case .stepTotal(let value) = $0.value { return value }
      return nil
    }.max()
    if maximumStepTotal.map({ $0 >= 3_000 }) == true {
      return "今天我们经过了一段很长的路。"
    }
    if kinds.contains(.sharedWalk) || kinds.contains(.fastPace) {
      return "今天我们一起走过了一段路。"
    }
    if kinds.contains(.pausedTogether) {
      return "今天你停下来的时候，我也陪你坐了一会儿。"
    }
    if kinds.contains(.sleepReflection) {
      return "今天醒来时，我还记得我们昨晚一起休息过。"
    }
    return "今天也有一小段只属于我们的共同记忆。"
  }

  private static func localDay(
    for date: Date,
    timeZone: TimeZone
  ) -> LocalDay {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return LocalDay(
      String(
        format: "%04d-%02d-%02d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0
      )
    )
  }

  private static func isEarlier(
    _ lhs: PassiveCompanionEvent,
    _ rhs: PassiveCompanionEvent
  ) -> Bool {
    if lhs.observedAt != rhs.observedAt {
      return lhs.observedAt < rhs.observedAt
    }
    return lhs.header.recordID < rhs.header.recordID
  }

  private static func evidenceReferenceOrder(
    _ lhs: EvidenceReference,
    _ rhs: EvidenceReference
  ) -> Bool {
    if lhs.kind != rhs.kind {
      return lhs.kind.rawValue < rhs.kind.rawValue
    }
    return lhs.id < rhs.id
  }
}

public actor DailyMemoryRuntime<Clock: MoriExperienceClock> {
  private let clock: Clock
  private let policy: DailyMemoryCompositionPolicy
  private var locallySealed: [LocalSealKey: MemoryRecord] = [:]

  public init(
    clock: Clock,
    policy: DailyMemoryCompositionPolicy = DailyMemoryCompositionPolicy()
  ) {
    self.clock = clock
    self.policy = policy
  }

  public func compose(
    state: ProfileState,
    timeZone: TimeZone,
    deviceRole: DailyMemoryDeviceRole,
    authoredRevision: LamportRevision
  ) async -> DailyMemoryCompositionOutcome {
    let outcome = policy.compose(
      state: state,
      at: await clock.now(),
      timeZone: timeZone,
      deviceRole: deviceRole,
      authoredRevision: authoredRevision
    )
    switch outcome {
    case .sealed(let candidate):
      let key = LocalSealKey(memory: candidate)
      if let existing = locallySealed[key] {
        return .alreadySealed(existing)
      }
      locallySealed[key] = candidate
      return .sealed(candidate)
    case .alreadySealed(let authoritative):
      locallySealed[LocalSealKey(memory: authoritative)] = authoritative
      return .alreadySealed(authoritative)
    case .unavailable:
      return outcome
    }
  }

  private struct LocalSealKey: Hashable {
    let memoryID: MemoryID
    let profileID: ProfileID
    let profileEpoch: ProfileEpoch
    let deletionEpoch: DeletionEpoch

    init(memory: MemoryRecord) {
      memoryID = memory.header.recordID
      profileID = memory.header.profileID
      profileEpoch = memory.header.profileEpoch
      deletionEpoch = memory.header.deletionEpoch
    }
  }
}
