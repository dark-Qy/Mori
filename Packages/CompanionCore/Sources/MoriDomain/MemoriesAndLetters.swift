import Foundation

public struct LocalDay: RawRepresentable, Hashable, Codable, Sendable, Comparable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public var isValid: Bool {
    guard rawValue.count == 10 else { return false }
    let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
    guard
      parts.count == 3,
      parts[0].count == 4,
      parts[1].count == 2,
      parts[2].count == 2,
      let year = Int(parts[0]),
      let month = Int(parts[1]),
      let day = Int(parts[2])
    else {
      return false
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let requested = DateComponents(year: year, month: month, day: day)
    guard let date = calendar.date(from: requested) else { return false }
    let resolved = calendar.dateComponents([.year, .month, .day], from: date)
    return resolved.year == year && resolved.month == month && resolved.day == day
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

extension StableIdentifier where Tag == MemoryIDTag {
  public static func daily(
    profileID: ProfileID,
    profileEpoch: ProfileEpoch,
    localDay: LocalDay,
    timeZoneIdentifier: String
  ) -> Self {
    let input = [
      "daily-memory-v1",
      profileID.rawValue,
      String(profileEpoch.revision.counter),
      profileEpoch.revision.originDeviceID,
      localDay.rawValue,
      timeZoneIdentifier,
    ].joined(separator: "\u{1F}")
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in input.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return Self("daily-\(String(hash, radix: 16))")
  }
}

public struct MemoryFactReference: Hashable, Codable, Sendable {
  public let evidenceID: EvidenceID
  public let kind: EvidenceKind
  public let sourceEventID: EventID

  public init(
    evidenceID: EvidenceID,
    kind: EvidenceKind,
    sourceEventID: EventID
  ) {
    self.evidenceID = evidenceID
    self.kind = kind
    self.sourceEventID = sourceEventID
  }
}

public struct SealedMemoryContent: Hashable, Codable, Sendable {
  public let facts: [MemoryFactReference]
  public let narrative: String
  public let sceneID: String
  public let moriActionID: String
  public let sealedAt: Date

  public init(
    facts: [MemoryFactReference],
    narrative: String,
    sceneID: String,
    moriActionID: String,
    sealedAt: Date
  ) {
    self.facts = facts
    self.narrative = narrative
    self.sceneID = sceneID
    self.moriActionID = moriActionID
    self.sealedAt = sealedAt
  }

  public var isValid: Bool {
    facts.isEmpty == false
      && facts.allSatisfy { $0.evidenceID.isValid && $0.sourceEventID.isValid }
      && narrative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      && sceneID.isEmpty == false
      && moriActionID.isEmpty == false
  }
}

public enum MemoryLifecycle: Hashable, Codable, Sendable {
  case draft
  case sealed(SealedMemoryContent)
  case deleted(at: Date, revision: LamportRevision)

  public var isSealed: Bool {
    if case .sealed = self { return true }
    return false
  }

  public var isDeleted: Bool {
    if case .deleted = self { return true }
    return false
  }
}

public enum MemoryTransitionKind: Hashable, Codable, Sendable {
  case seal(SealedMemoryContent)
  case delete(at: Date)
}

public struct MemoryTransition: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<MemoryTransitionID>
  public let memoryID: MemoryID
  public let revision: LamportRevision
  public let kind: MemoryTransitionKind

  public init(
    header: ProfileScopedRecordHeader<MemoryTransitionID>,
    memoryID: MemoryID,
    revision: LamportRevision,
    kind: MemoryTransitionKind
  ) {
    self.header = header
    self.memoryID = memoryID
    self.revision = revision
    self.kind = kind
  }
}

public struct MemoryRecord: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<MemoryID>
  public let localDay: LocalDay
  public let timeZoneIdentifier: String
  public let authoredRevision: LamportRevision
  public private(set) var lifecycle: MemoryLifecycle
  public private(set) var winningTransitionID: MemoryTransitionID?

  public init(
    header: ProfileScopedRecordHeader<MemoryID>,
    localDay: LocalDay,
    timeZoneIdentifier: String,
    authoredRevision: LamportRevision,
    lifecycle: MemoryLifecycle = .draft,
    winningTransitionID: MemoryTransitionID? = nil
  ) {
    self.header = header
    self.localDay = localDay
    self.timeZoneIdentifier = timeZoneIdentifier
    self.authoredRevision = authoredRevision
    self.lifecycle = lifecycle
    self.winningTransitionID = winningTransitionID
  }

  public func validate(in profile: RuntimeProfile) -> MoriDomainRejection? {
    guard header.schemaVersion == 1 else { return .invalidSchema }
    guard
      header.recordID.isValid,
      localDay.isValid,
      TimeZone(identifier: timeZoneIdentifier) != nil,
      authoredRevision.isValid
    else {
      return .invalidRecord
    }
    guard header.profileID == profile.id else { return .profileMismatch }
    guard header.profileEpoch == profile.epoch else { return .profileEpochMismatch }
    guard header.deletionEpoch == profile.deletionEpoch else { return .deletionEpochMismatch }
    let expectedID = MemoryID.daily(
      profileID: profile.id,
      profileEpoch: profile.epoch,
      localDay: localDay,
      timeZoneIdentifier: timeZoneIdentifier
    )
    guard header.recordID == expectedID else { return .invalidIdentifier }
    switch lifecycle {
    case .draft:
      guard winningTransitionID == nil else { return .invalidRecord }
    case .sealed(let content):
      guard
        content.isValid,
        winningTransitionID?.isValid ?? true
      else {
        return .invalidRecord
      }
    case .deleted(_, let revision):
      guard
        revision.isValid,
        revision >= authoredRevision,
        let winningTransitionID,
        winningTransitionID.isValid
      else {
        return .invalidRecord
      }
    }
    if let winningTransitionID, winningTransitionID.isValid == false {
      return .invalidRecord
    }
    return nil
  }

  public mutating func apply(
    _ transition: MemoryTransition,
    in profile: RuntimeProfile
  ) -> MutationResult {
    guard transition.header.schemaVersion == 1 else {
      return .rejected(.invalidSchema)
    }
    guard
      transition.header.scopeMatches(profile),
      header.scopeMatches(profile)
    else {
      return .rejected(.profileMismatch)
    }
    guard
      transition.header.recordID.isValid,
      transition.memoryID == header.recordID,
      transition.revision.isValid,
      transition.revision >= authoredRevision
    else {
      return .rejected(.invalidRecord)
    }
    if case .seal(let content) = transition.kind, content.isValid == false {
      return .rejected(.invalidRecord)
    }
    if transition.header.recordID == winningTransitionID {
      switch (lifecycle, transition.kind) {
      case (.sealed(let existing), .seal(let incoming)) where existing == incoming:
        return .duplicate
      case (.deleted(_, let revision), .delete) where revision == transition.revision:
        return .duplicate
      default:
        return .rejected(.conflictingDuplicate)
      }
    }
    switch (lifecycle, transition.kind) {
    case (.deleted, _):
      // Delete is terminal. Later valid seal/delete transitions are converged
      // no-ops so fixed-point replay can consume every terminal loser.
      return .duplicate
    case (_, let .delete(at)):
      lifecycle = .deleted(at: at, revision: transition.revision)
      winningTransitionID = transition.header.recordID
      return .applied
    case (.sealed, .seal):
      // The authority seals once. Evidence that arrives afterwards cannot alter it.
      return .duplicate
    case (.draft, let .seal(content)):
      lifecycle = .sealed(content)
      winningTransitionID = transition.header.recordID
      return .applied
    }
  }
}

public enum LetterSource: Hashable, Codable, Sendable {
  case event(EventID)
  case memory(MemoryID)
}

public enum LetterTransitionKind: Hashable, Codable, Sendable {
  case read(at: Date)
  case delete(at: Date)
}

public struct LetterTransition: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<LetterTransitionID>
  public let letterID: LetterID
  public let revision: LamportRevision
  public let kind: LetterTransitionKind

  public init(
    header: ProfileScopedRecordHeader<LetterTransitionID>,
    letterID: LetterID,
    revision: LamportRevision,
    kind: LetterTransitionKind
  ) {
    self.header = header
    self.letterID = letterID
    self.revision = revision
    self.kind = kind
  }
}

public struct LetterRecord: Hashable, Codable, Sendable {
  public let header: ProfileScopedRecordHeader<LetterID>
  public let source: LetterSource
  public let title: String
  public let body: String
  public let deliveredAt: Date
  public let authoredRevision: LamportRevision
  public private(set) var readAt: Date?
  public private(set) var readRevision: LamportRevision?
  public private(set) var readTransitionID: LetterTransitionID?
  public private(set) var deletedAt: Date?
  public private(set) var deletionRevision: LamportRevision?
  public private(set) var deletionTransitionID: LetterTransitionID?

  public init(
    header: ProfileScopedRecordHeader<LetterID>,
    source: LetterSource,
    title: String,
    body: String,
    deliveredAt: Date,
    authoredRevision: LamportRevision,
    readAt: Date? = nil,
    readRevision: LamportRevision? = nil,
    readTransitionID: LetterTransitionID? = nil,
    deletedAt: Date? = nil,
    deletionRevision: LamportRevision? = nil,
    deletionTransitionID: LetterTransitionID? = nil
  ) {
    self.header = header
    self.source = source
    self.title = title
    self.body = body
    self.deliveredAt = deliveredAt
    self.authoredRevision = authoredRevision
    self.readAt = readAt
    self.readRevision = readRevision
    self.readTransitionID = readTransitionID
    self.deletedAt = deletedAt
    self.deletionRevision = deletionRevision
    self.deletionTransitionID = deletionTransitionID
  }

  public var isRead: Bool { readRevision != nil }
  public var isDeleted: Bool { deletionRevision != nil }

  public func validate(in profile: RuntimeProfile) -> MoriDomainRejection? {
    guard header.schemaVersion == 1 else { return .invalidSchema }
    guard
      header.recordID.isValid,
      authoredRevision.isValid,
      title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      (readAt == nil) == (readRevision == nil),
      (readAt == nil) == (readTransitionID == nil),
      (deletedAt == nil) == (deletionRevision == nil),
      (deletedAt == nil) == (deletionTransitionID == nil),
      readRevision?.isValid ?? true,
      deletionRevision?.isValid ?? true,
      readRevision.map({ $0 >= authoredRevision }) ?? true,
      deletionRevision.map({ $0 >= authoredRevision }) ?? true,
      readTransitionID?.isValid ?? true,
      deletionTransitionID?.isValid ?? true
    else {
      return .invalidRecord
    }
    guard header.profileID == profile.id else { return .profileMismatch }
    guard header.profileEpoch == profile.epoch else { return .profileEpochMismatch }
    guard header.deletionEpoch == profile.deletionEpoch else { return .deletionEpochMismatch }
    switch source {
    case .event(let id): guard id.isValid else { return .invalidIdentifier }
    case .memory(let id): guard id.isValid else { return .invalidIdentifier }
    }
    return nil
  }

  public mutating func apply(
    _ transition: LetterTransition,
    in profile: RuntimeProfile
  ) -> MutationResult {
    guard header.scopeMatches(profile), transition.header.scopeMatches(profile) else {
      return .rejected(.profileMismatch)
    }
    guard
      transition.header.recordID.isValid,
      transition.letterID == header.recordID,
      transition.revision.isValid,
      transition.revision >= authoredRevision
    else {
      return .rejected(.invalidRecord)
    }
    switch transition.kind {
    case .read(let at):
      // Delete wins over every read. A read delivered after deletion is a
      // converged terminal no-op, not a missing dependency that should remain
      // in the sync retry queue forever.
      guard isDeleted == false else { return .duplicate }
      if transition.header.recordID == readTransitionID { return .duplicate }
      if let current = readRevision {
        guard current != transition.revision else {
          return .rejected(.conflictingDuplicate)
        }
        guard current < transition.revision else { return .duplicate }
      }
      readAt = at
      readRevision = transition.revision
      readTransitionID = transition.header.recordID
      return .applied
    case .delete(let at):
      if transition.header.recordID == deletionTransitionID { return .duplicate }
      if let current = deletionRevision {
        guard current != transition.revision else {
          return .rejected(.conflictingDuplicate)
        }
        guard current < transition.revision else { return .duplicate }
      }
      deletedAt = at
      deletionRevision = transition.revision
      deletionTransitionID = transition.header.recordID
      return .applied
    }
  }

  public func merged(with other: Self, in profile: RuntimeProfile) -> LetterMergeResult {
    guard header.scopeMatches(profile), other.header.scopeMatches(profile) else {
      return .rejected(.profileMismatch)
    }
    guard header.recordID == other.header.recordID else {
      return .rejected(.invalidRecord)
    }
    guard
      source == other.source,
      title == other.title,
      body == other.body,
      deliveredAt == other.deliveredAt,
      authoredRevision == other.authoredRevision
    else {
      return .rejected(.conflictingDuplicate)
    }
    if let lhsRevision = deletionRevision, let rhsRevision = other.deletionRevision,
      lhsRevision == rhsRevision,
      deletionTransitionID != other.deletionTransitionID || deletedAt != other.deletedAt
    {
      return .rejected(.conflictingDuplicate)
    }
    if let lhsRevision = readRevision, let rhsRevision = other.readRevision,
      lhsRevision == rhsRevision,
      readTransitionID != other.readTransitionID || readAt != other.readAt
    {
      return .rejected(.conflictingDuplicate)
    }

    var result = self
    if let otherDeletion = other.deletionRevision,
      result.deletionRevision.map({ $0 < otherDeletion }) ?? true
    {
      result.deletedAt = other.deletedAt
      result.deletionRevision = otherDeletion
      result.deletionTransitionID = other.deletionTransitionID
    }
    if result.deletionRevision == nil,
      let otherRead = other.readRevision,
      result.readRevision.map({ $0 < otherRead }) ?? true
    {
      result.readAt = other.readAt
      result.readRevision = otherRead
      result.readTransitionID = other.readTransitionID
    }
    return result == self ? .duplicate : .merged(result)
  }
}

public enum LetterMergeResult: Hashable, Codable, Sendable {
  case merged(LetterRecord)
  case duplicate
  case rejected(MoriDomainRejection)
}
