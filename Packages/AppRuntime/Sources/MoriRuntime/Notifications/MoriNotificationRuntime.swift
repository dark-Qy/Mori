import Foundation
import MoriDomain
import MoriPersistence

public struct MoriNotificationHistoryEntry:
  Hashable, Codable, Sendable
{
  public let stableRequestID: String
  public let kind: MoriNotificationKind
  public let budgetDay: LocalDay
  public let timeZoneIdentifier: String
  public let scheduledAt: Date

  public init(
    stableRequestID: String,
    kind: MoriNotificationKind,
    budgetDay: LocalDay,
    timeZoneIdentifier: String,
    scheduledAt: Date
  ) {
    self.stableRequestID = stableRequestID
    self.kind = kind
    self.budgetDay = budgetDay
    self.timeZoneIdentifier = timeZoneIdentifier
    self.scheduledAt = scheduledAt
  }
}

public enum MoriNotificationCommandAction:
  Hashable, Codable, Sendable
{
  case schedule(MoriNotificationRequest)
  case cancel(stableRequestID: String, deletionEpoch: DeletionEpoch)

  var stableRequestID: String {
    switch self {
    case .schedule(let request): request.stableRequestID
    case .cancel(let stableRequestID, _): stableRequestID
    }
  }

  var deletionEpoch: DeletionEpoch {
    switch self {
    case .schedule(let request): request.profileDeletionEpoch
    case .cancel(_, let deletionEpoch): deletionEpoch
    }
  }

  var actionName: String {
    switch self {
    case .schedule: "schedule"
    case .cancel: "cancel"
    }
  }
}

public struct MoriNotificationCommand:
  Hashable, Codable, Sendable
{
  public let operationID: String
  public let sequence: UInt64
  public let action: MoriNotificationCommandAction

  public init(
    operationID: String,
    sequence: UInt64,
    action: MoriNotificationCommandAction
  ) {
    self.operationID = operationID
    self.sequence = sequence
    self.action = action
  }

  static func make(
    sequence: UInt64,
    action: MoriNotificationCommandAction
  ) -> Self {
    let epoch = action.deletionEpoch
    let operationID = [
      "mori.notification.command",
      String(sequence),
      action.actionName,
      action.stableRequestID,
      epoch.requestID.rawValue,
      String(epoch.revision.counter),
      epoch.revision.originDeviceID,
    ].joined(separator: ".")
    return Self(
      operationID: operationID,
      sequence: sequence,
      action: action
    )
  }

  var isValid: Bool {
    operationID == Self.make(sequence: sequence, action: action).operationID
      && action.deletionEpoch.isValid
      && {
        switch action {
        case .schedule(let request):
          MoriNotificationSnapshot.requestIsValid(request)
        case .cancel(let stableRequestID, _):
          !stableRequestID.trimmingCharacters(
            in: .whitespacesAndNewlines
          ).isEmpty
        }
      }()
  }
}

public struct MoriNotificationSnapshot: Hashable, Codable, Sendable {
  public static let currentSchemaVersion: UInt16 = 2
  public static let maximumPendingCount = 64
  public static let maximumDeliveredCount = 64
  public static let maximumActiveRequestCount = 64
  public static let maximumHistoryCount = 128
  public static let maximumCommandCount = 128

  public let schemaVersion: UInt16
  public let pending: [MoriNotificationRequest]
  public let delivered: [MoriNotificationRequest]
  public let history: [MoriNotificationHistoryEntry]
  fileprivate let commands: [MoriNotificationCommand]
  public let nextCommandSequence: UInt64

  public init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    pending: [MoriNotificationRequest] = [],
    delivered: [MoriNotificationRequest] = [],
    history: [MoriNotificationHistoryEntry] = [],
    nextCommandSequence: UInt64 = 1
  ) {
    self.init(
      schemaVersion: schemaVersion,
      pending: pending,
      delivered: delivered,
      history: history,
      commands: [],
      nextCommandSequence: nextCommandSequence
    )
  }

  init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    pending: [MoriNotificationRequest] = [],
    delivered: [MoriNotificationRequest] = [],
    history: [MoriNotificationHistoryEntry] = [],
    commands: [MoriNotificationCommand],
    nextCommandSequence: UInt64 = 1
  ) {
    self.schemaVersion = schemaVersion
    self.pending = pending.sorted {
      $0.stableRequestID < $1.stableRequestID
    }
    self.delivered = delivered.sorted(by: Self.requestOrder)
    self.history = history.sorted(by: Self.historyOrder)
    self.commands = commands.sorted { $0.sequence < $1.sequence }
    self.nextCommandSequence = nextCommandSequence
  }

  public var isValid: Bool {
    let pendingIDs = pending.map(\.stableRequestID)
    let deliveredIDs = delivered.map(\.stableRequestID)
    let activeIDs = pendingIDs + deliveredIDs
    let commandIDs = commands.map(\.operationID)
    let commandSequences = commands.map(\.sequence)
    return schemaVersion == Self.currentSchemaVersion
      && pending.count <= Self.maximumPendingCount
      && delivered.count <= Self.maximumDeliveredCount
      && activeIDs.count <= Self.maximumActiveRequestCount
      && history.count <= Self.maximumHistoryCount
      && commands.count <= Self.maximumCommandCount
      && nextCommandSequence < UInt64.max
      && Set(pendingIDs).count == pendingIDs.count
      && Set(deliveredIDs).count == deliveredIDs.count
      && Set(activeIDs).count == activeIDs.count
      && Set(commandIDs).count == commandIDs.count
      && Set(commandSequences).count == commandSequences.count
      && pending
        == pending.sorted {
          $0.stableRequestID < $1.stableRequestID
        }
      && delivered == delivered.sorted(by: Self.requestOrder)
      && history == history.sorted(by: Self.historyOrder)
      && commands == commands.sorted { $0.sequence < $1.sequence }
      && commands.allSatisfy {
        $0.isValid && $0.sequence < nextCommandSequence
      }
      && pending.allSatisfy(Self.requestIsValid)
      && delivered.allSatisfy(Self.requestIsValid)
      && activeRequests.allSatisfy {
        Self.historyContainsExactRequest($0, history: history)
      }
      && Self.historyIsValid(history)
      && commands.allSatisfy { command in
        guard case .schedule(let request) = command.action else {
          return true
        }
        return activeRequests.contains(request)
          && Self.historyContainsExactRequest(request, history: history)
      }
  }

  fileprivate var activeRequests: [MoriNotificationRequest] {
    pending + delivered
  }

  private static func historyContainsExactRequest(
    _ request: MoriNotificationRequest,
    history: [MoriNotificationHistoryEntry]
  ) -> Bool {
    history.contains {
      $0.stableRequestID == request.stableRequestID
        && $0.kind == request.kind
        && $0.budgetDay == request.budgetDay
        && $0.timeZoneIdentifier == request.timeZoneIdentifier
        && $0.scheduledAt == request.scheduledAt
    }
  }

  private static func historyIsValid(
    _ history: [MoriNotificationHistoryEntry]
  ) -> Bool {
    guard
      history.allSatisfy({ entry in
        guard
          let timeZone = TimeZone(
            identifier: entry.timeZoneIdentifier
          )
        else {
          return false
        }
        return !entry.stableRequestID.isEmpty
          && entry.budgetDay.isValid
          && entry.budgetDay
            == MoriNotificationLocalDay.resolve(
              entry.scheduledAt,
              timeZone: timeZone
            )
          && entry.scheduledAt.timeIntervalSinceReferenceDate.isFinite
      })
    else {
      return false
    }
    let dayGroups = Dictionary(grouping: history, by: \.budgetDay)
    guard
      dayGroups.values.allSatisfy({ entries in
        entries.count <= 2
          && Set(entries.map(\.kind)).count == entries.count
      })
    else {
      return false
    }
    let letters = history.filter { $0.kind == .letter }
    return zip(letters, letters.dropFirst()).allSatisfy { pair in
      pair.1.scheduledAt.timeIntervalSince(pair.0.scheduledAt)
        >= MoriNotificationRuntimePolicy.letterCooldown
    }
  }

  fileprivate static func requestIsValid(
    _ request: MoriNotificationRequest
  ) -> Bool {
    request.stableRequestID
      == MoriNotificationRequestIdentity.make(
        kind: request.kind,
        profileID: request.route.profileID,
        profileEpoch: request.route.profileEpoch,
        objectID: request.route.objectID
      )
      && request.route.schemaVersion
        == MoriNotificationRoute.currentSchemaVersion
      && request.kind == request.route.kind
      && request.route.profileID.isValid
      && request.route.profileEpoch.isValid
      && request.profileDeletionEpoch.isValid
      && request.contentRevision.isValid
      && request.budgetDay.isValid
      && {
        guard
          let timeZone = TimeZone(
            identifier: request.timeZoneIdentifier
          )
        else {
          return false
        }
        return request.budgetDay
          == MoriNotificationLocalDay.resolve(
            request.scheduledAt,
            timeZone: timeZone
          )
      }()
      && !request.route.objectID.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
      && !request.title.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
      && !request.body.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
      && request.scheduledAt.timeIntervalSinceReferenceDate.isFinite
  }

  private static func historyOrder(
    _ lhs: MoriNotificationHistoryEntry,
    _ rhs: MoriNotificationHistoryEntry
  ) -> Bool {
    if lhs.scheduledAt != rhs.scheduledAt {
      return lhs.scheduledAt < rhs.scheduledAt
    }
    return lhs.stableRequestID < rhs.stableRequestID
  }

  private static func requestOrder(
    _ lhs: MoriNotificationRequest,
    _ rhs: MoriNotificationRequest
  ) -> Bool {
    if lhs.scheduledAt != rhs.scheduledAt {
      return lhs.scheduledAt < rhs.scheduledAt
    }
    return lhs.stableRequestID < rhs.stableRequestID
  }
}

public struct MoriNotificationMutation: Hashable, Sendable {
  public let snapshot: MoriNotificationSnapshot
  public let commands: [MoriNotificationCommand]

  public init(snapshot: MoriNotificationSnapshot) {
    self.snapshot = snapshot
    commands = snapshot.commands.first.map { [$0] } ?? []
  }
}

public enum MoriNotificationRuntimeError: Error, Equatable, Sendable {
  case outOfOrderAcknowledgement(
    expectedOperationID: String,
    receivedOperationID: String
  )
}

/// Applies the frozen ADR 0004 budget: one daily memory per local day, one
/// letter per local day, six hours between letters, and two notifications total
/// per local day. Persistent history and a rollback fence make the result
/// independent of relaunch and wall-clock rollback.
public struct MoriNotificationRuntimePolicy: Sendable {
  public static let letterCooldown: TimeInterval = 6 * 60 * 60

  public init() {}

  public func inserting(
    _ request: MoriNotificationRequest,
    into snapshot: MoriNotificationSnapshot
  ) -> Result<MoriNotificationSnapshot, MoriNotificationSuppression> {
    guard MoriNotificationSnapshot.requestIsValid(request) else {
      return .failure(.invalidContent)
    }
    guard
      !snapshot.activeRequests.contains(where: {
        $0.stableRequestID == request.stableRequestID
      })
    else {
      return .failure(.alreadyPending)
    }
    if let latest = snapshot.history.last?.scheduledAt,
      request.scheduledAt < latest
    {
      return .failure(.clockRollback)
    }

    let dayHistory = snapshot.history.filter {
      $0.budgetDay == request.budgetDay
    }
    guard dayHistory.count < 2 else {
      return .failure(.totalDailyBudget)
    }
    guard
      !dayHistory.contains(where: { $0.kind == request.kind })
    else {
      return .failure(.kindDailyBudget)
    }
    if request.kind == .letter,
      let lastLetter = snapshot.history.last(where: {
        $0.kind == .letter
      }),
      request.scheduledAt.timeIntervalSince(lastLetter.scheduledAt)
        < Self.letterCooldown
    {
      return .failure(.cooldown)
    }
    guard
      snapshot.activeRequests.count
        < MoriNotificationSnapshot.maximumActiveRequestCount
    else {
      return .failure(.activeRequestCapacity)
    }

    let allHistory =
      snapshot.history + [
        MoriNotificationHistoryEntry(
          stableRequestID: request.stableRequestID,
          kind: request.kind,
          budgetDay: request.budgetDay,
          timeZoneIdentifier: request.timeZoneIdentifier,
          scheduledAt: request.scheduledAt
        )
      ]
    let activeRequests = snapshot.activeRequests + [request]
    let requiredHistory = allHistory.filter { entry in
      activeRequests.contains {
        $0.stableRequestID == entry.stableRequestID
          && $0.kind == entry.kind
          && $0.budgetDay == entry.budgetDay
          && $0.timeZoneIdentifier == entry.timeZoneIdentifier
          && $0.scheduledAt == entry.scheduledAt
      }
    }
    let inactiveHistory = allHistory.filter { entry in
      !requiredHistory.contains(entry)
    }
    let remainingHistoryCapacity =
      MoriNotificationSnapshot.maximumHistoryCount
      - requiredHistory.count
    let newHistory =
      requiredHistory
      + inactiveHistory.suffix(remainingHistoryCapacity)
    return .success(
      MoriNotificationSnapshot(
        pending: snapshot.pending + [request],
        delivered: snapshot.delivered,
        history: newHistory,
        commands: snapshot.commands,
        nextCommandSequence: snapshot.nextCommandSequence
      )
    )
  }

  public func obsoleteRequestIDs(
    in snapshot: MoriNotificationSnapshot,
    state: ProfileState,
    consent: GlobalConsentState,
    localAuthorization: MoriNotificationAuthorization
  ) -> Set<String> {
    Set(
      snapshot.activeRequests.compactMap {
        isStillEligible(
          $0,
          state: state,
          consent: consent,
          localAuthorization: localAuthorization
        )
          ? nil
          : $0.stableRequestID
      }
    )
  }

  private func isStillEligible(
    _ request: MoriNotificationRequest,
    state: ProfileState,
    consent: GlobalConsentState,
    localAuthorization: MoriNotificationAuthorization
  ) -> Bool {
    guard
      consent.isValid,
      consent.proactiveNotifications.enabled,
      consent.proactiveNotifications.isValid(for: .proactiveNotifications),
      consent[request.kind.requiredConsentKind].enabled,
      consent[request.kind.requiredConsentKind].isValid(
        for: request.kind.requiredConsentKind
      ),
      localAuthorization == .authorized,
      request.route.profileID == state.runtimeProfile.id,
      request.route.profileEpoch == state.runtimeProfile.epoch,
      request.profileDeletionEpoch == state.runtimeProfile.deletionEpoch,
      MoriNotificationRouteResolver().resolve(
        request.route,
        state: state
      ) != nil
    else {
      return false
    }

    switch request.kind {
    case .dailyMemory:
      let id = MemoryID(request.route.objectID)
      return state.memories.first(where: {
        $0.header.recordID == id
      })?.authoredRevision == request.contentRevision
    case .letter:
      let id = LetterID(request.route.objectID)
      guard
        let letter = state.letters.first(where: {
          $0.header.recordID == id
        })
      else {
        return false
      }
      return letter.authoredRevision == request.contentRevision
        && !letter.isRead
        && !letter.isDeleted
    }
  }
}

public enum MoriNotificationSnapshotCodecError:
  Error, Equatable, Sendable
{
  case oversized
  case malformed
  case invalidSnapshot
}

public struct MoriNotificationSnapshotCodec: Sendable {
  public static let defaultMaximumBytes = 128 * 1_024

  private let maximumBytes: Int
  private let codec: CanonicalJSONCodec

  public init(
    maximumBytes: Int = Self.defaultMaximumBytes,
    codec: CanonicalJSONCodec = CanonicalJSONCodec()
  ) {
    self.maximumBytes = max(1, maximumBytes)
    self.codec = codec
  }

  public func encode(_ snapshot: MoriNotificationSnapshot) throws -> Data {
    guard snapshot.isValid else {
      throw MoriNotificationSnapshotCodecError.invalidSnapshot
    }
    let data = try codec.encode(snapshot)
    guard data.count <= maximumBytes else {
      throw MoriNotificationSnapshotCodecError.oversized
    }
    return data
  }

  public func decode(_ data: Data) throws -> MoriNotificationSnapshot {
    guard data.count <= maximumBytes else {
      throw MoriNotificationSnapshotCodecError.oversized
    }
    let snapshot: MoriNotificationSnapshot
    do {
      snapshot = try codec.decode(MoriNotificationSnapshot.self, from: data)
    } catch {
      throw MoriNotificationSnapshotCodecError.malformed
    }
    guard snapshot.isValid else {
      throw MoriNotificationSnapshotCodecError.invalidSnapshot
    }
    guard
      let source = try? JSONSerialization.jsonObject(with: data),
      let canonicalData = try? codec.encode(snapshot),
      let canonical = try? JSONSerialization.jsonObject(with: canonicalData),
      data == canonicalData,
      !containsUndeclaredField(source: source, canonical: canonical)
    else {
      throw MoriNotificationSnapshotCodecError.malformed
    }
    return snapshot
  }

  private func containsUndeclaredField(
    source: Any,
    canonical: Any
  ) -> Bool {
    if let source = source as? [String: Any] {
      guard let canonical = canonical as? [String: Any] else { return true }
      for key in source.keys {
        guard
          let sourceValue = source[key],
          let canonicalValue = canonical[key],
          !containsUndeclaredField(
            source: sourceValue,
            canonical: canonicalValue
          )
        else {
          return true
        }
      }
      return false
    }
    if let source = source as? [Any] {
      guard
        let canonical = canonical as? [Any],
        source.count == canonical.count
      else {
        return true
      }
      return zip(source, canonical).contains { pair in
        containsUndeclaredField(source: pair.0, canonical: pair.1)
      }
    }
    return false
  }
}

public protocol MoriNotificationSnapshotStorage: Sendable {
  func load() async throws -> Data?
  func save(_ data: Data) async throws
}

public actor InMemoryMoriNotificationSnapshotStorage:
  MoriNotificationSnapshotStorage
{
  private var data: Data?

  public init(data: Data? = nil) {
    self.data = data
  }

  public func load() -> Data? {
    data
  }

  public func save(_ data: Data) {
    self.data = data
  }
}

public actor FileMoriNotificationSnapshotStorage:
  MoriNotificationSnapshotStorage
{
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }
    return try Data(contentsOf: fileURL)
  }

  public func save(_ data: Data) throws {
    try ProtectedAtomicFile.write(data, to: fileURL)
  }
}

/// Durable command outbox for the iPhone notification adapter. Every OS
/// schedule/cancel remains replayable until the adapter explicitly
/// acknowledges its operation ID.
public actor MoriNotificationRuntime<
  Storage: MoriNotificationSnapshotStorage
> {
  private let storage: Storage
  private let codec: MoriNotificationSnapshotCodec
  private let policy: MoriNotificationRuntimePolicy
  private var cached: MoriNotificationSnapshot?
  private var operationIsActive = false
  private var operationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    storage: Storage,
    codec: MoriNotificationSnapshotCodec = MoriNotificationSnapshotCodec(),
    policy: MoriNotificationRuntimePolicy = MoriNotificationRuntimePolicy()
  ) {
    self.storage = storage
    self.codec = codec
    self.policy = policy
  }

  public func current() async throws -> MoriNotificationSnapshot {
    await acquireOperation()
    defer { releaseOperation() }
    return try await loadIfNeeded()
  }

  public func nextCommand() async throws -> MoriNotificationCommand? {
    try await current().commands.first
  }

  public func schedule(
    memory: MemoryRecord,
    state: ProfileState,
    context: MoriNotificationSchedulingContext
  ) async throws -> Result<
    MoriNotificationMutation,
    MoriNotificationSuppression
  > {
    await acquireOperation()
    defer { releaseOperation() }
    var current = try await loadIfNeeded()
    let loaded = current
    current = applyingCurrentAuthority(
      to: current,
      state: state,
      consent: context.consent,
      localAuthorization: context.localAuthorization
    )
    guard
      state.validate() == nil,
      state.runtimeProfile == context.activeProfile,
      state.memories.contains(memory)
    else {
      if current != loaded {
        try await persist(current)
      }
      return .failure(.invalidContent)
    }
    return try await scheduleLocked(
      MoriNotificationPolicy().plan(
        memory: memory,
        context: context
      ),
      current: current,
      original: loaded
    )
  }

  public func schedule(
    letter: LetterRecord,
    state: ProfileState,
    context: MoriNotificationSchedulingContext
  ) async throws -> Result<
    MoriNotificationMutation,
    MoriNotificationSuppression
  > {
    await acquireOperation()
    defer { releaseOperation() }
    var current = try await loadIfNeeded()
    let loaded = current
    current = applyingCurrentAuthority(
      to: current,
      state: state,
      consent: context.consent,
      localAuthorization: context.localAuthorization
    )
    guard
      state.validate() == nil,
      state.runtimeProfile == context.activeProfile,
      state.letters.contains(letter)
    else {
      if current != loaded {
        try await persist(current)
      }
      return .failure(.invalidContent)
    }
    return try await scheduleLocked(
      MoriNotificationPolicy().plan(
        letter: letter,
        context: context
      ),
      current: current,
      original: loaded
    )
  }

  private func scheduleLocked(
    _ candidate: MoriNotificationCandidatePlan,
    current: MoriNotificationSnapshot,
    original: MoriNotificationSnapshot
  ) async throws -> Result<
    MoriNotificationMutation,
    MoriNotificationSuppression
  > {
    guard case .schedule(let request) = candidate else {
      if current != original {
        try await persist(current)
      }
      if case .suppressed(let reason) = candidate {
        return .failure(reason)
      }
      return .failure(.invalidContent)
    }

    var prepared = current
    var insertion = policy.inserting(request, into: prepared)
    if case .failure(.activeRequestCapacity) = insertion,
      let reclaimable = prepared.delivered.first(where: { delivered in
        !prepared.commands.contains {
          $0.action.stableRequestID == delivered.stableRequestID
        }
      })
    {
      prepared = replacingWithCancel(reclaimable, in: prepared)
      insertion = policy.inserting(request, into: prepared)
    }

    switch insertion {
    case .failure(.alreadyPending):
      if prepared != original {
        try await persist(prepared)
      }
      let outstanding = prepared.commands.contains {
        if case .schedule(let queued) = $0.action {
          return queued.stableRequestID == request.stableRequestID
        }
        return false
      }
      return outstanding
        ? .success(MoriNotificationMutation(snapshot: prepared))
        : .failure(.alreadyPending)
    case .failure(let suppression):
      if prepared != original {
        try await persist(prepared)
      }
      return .failure(suppression)
    case .success(let inserted):
      let updated = appending(
        .schedule(request),
        to: inserted
      )
      try await persist(updated)
      return .success(MoriNotificationMutation(snapshot: updated))
    }
  }

  public func reconcile(
    state: ProfileState,
    consent: GlobalConsentState,
    localAuthorization: MoriNotificationAuthorization
  ) async throws -> MoriNotificationMutation {
    await acquireOperation()
    defer { releaseOperation() }
    let current = try await loadIfNeeded()
    let updated = applyingCurrentAuthority(
      to: current,
      state: state,
      consent: consent,
      localAuthorization: localAuthorization
    )
    guard updated != current else {
      return MoriNotificationMutation(snapshot: current)
    }
    try await persist(updated)
    return MoriNotificationMutation(snapshot: updated)
  }

  public func acknowledge(
    operationID: String
  ) async throws -> MoriNotificationSnapshot {
    await acquireOperation()
    defer { releaseOperation() }
    let current = try await loadIfNeeded()
    guard
      let index = current.commands.firstIndex(where: {
        $0.operationID == operationID
      })
    else {
      return current
    }
    guard
      index == current.commands.startIndex,
      let expected = current.commands.first,
      expected.operationID == operationID
    else {
      throw MoriNotificationRuntimeError.outOfOrderAcknowledgement(
        expectedOperationID: current.commands[0].operationID,
        receivedOperationID: operationID
      )
    }
    let updated = MoriNotificationSnapshot(
      pending: current.pending,
      delivered: current.delivered,
      history: current.history,
      commands: Array(current.commands.dropFirst()),
      nextCommandSequence: current.nextCommandSequence
    )
    try await persist(updated)
    return updated
  }

  public func markDelivered(
    stableRequestID: String
  ) async throws -> MoriNotificationSnapshot {
    await acquireOperation()
    defer { releaseOperation() }
    let current = try await loadIfNeeded()
    guard
      let deliveredRequest = current.pending.first(where: {
        $0.stableRequestID == stableRequestID
      })
    else {
      return current
    }
    let updated = MoriNotificationSnapshot(
      pending: current.pending.filter {
        $0.stableRequestID != stableRequestID
      },
      delivered: current.delivered + [deliveredRequest],
      history: current.history,
      commands: current.commands,
      nextCommandSequence: current.nextCommandSequence
    )
    try await persist(updated)
    return updated
  }

  public func cancelAll() async throws -> MoriNotificationMutation {
    await acquireOperation()
    defer { releaseOperation() }
    let current = try await loadIfNeeded()
    var updated = current
    for request in current.activeRequests {
      updated = replacingWithCancel(request, in: updated)
    }
    if updated != current {
      try await persist(updated)
    }
    return MoriNotificationMutation(snapshot: updated)
  }

  private func replacingWithCancel(
    _ request: MoriNotificationRequest,
    in snapshot: MoriNotificationSnapshot
  ) -> MoriNotificationSnapshot {
    let withoutRequest = MoriNotificationSnapshot(
      pending: snapshot.pending.filter {
        $0.stableRequestID != request.stableRequestID
      },
      delivered: snapshot.delivered.filter {
        $0.stableRequestID != request.stableRequestID
      },
      history: snapshot.history,
      commands: snapshot.commands.filter {
        $0.action.stableRequestID != request.stableRequestID
      },
      nextCommandSequence: snapshot.nextCommandSequence
    )
    return appending(
      .cancel(
        stableRequestID: request.stableRequestID,
        deletionEpoch: request.profileDeletionEpoch
      ),
      to: withoutRequest
    )
  }

  private func applyingCurrentAuthority(
    to snapshot: MoriNotificationSnapshot,
    state: ProfileState,
    consent: GlobalConsentState,
    localAuthorization: MoriNotificationAuthorization
  ) -> MoriNotificationSnapshot {
    let obsolete = policy.obsoleteRequestIDs(
      in: snapshot,
      state: state,
      consent: consent,
      localAuthorization: localAuthorization
    )
    guard !obsolete.isEmpty else { return snapshot }
    var updated = snapshot
    for request in snapshot.activeRequests
    where obsolete.contains(request.stableRequestID) {
      updated = replacingWithCancel(request, in: updated)
    }
    return updated
  }

  private func appending(
    _ action: MoriNotificationCommandAction,
    to snapshot: MoriNotificationSnapshot
  ) -> MoriNotificationSnapshot {
    let command = MoriNotificationCommand.make(
      sequence: snapshot.nextCommandSequence,
      action: action
    )
    return MoriNotificationSnapshot(
      pending: snapshot.pending,
      delivered: snapshot.delivered,
      history: snapshot.history,
      commands: snapshot.commands + [command],
      nextCommandSequence: snapshot.nextCommandSequence + 1
    )
  }

  private func acquireOperation() async {
    guard !operationIsActive else {
      await withCheckedContinuation { continuation in
        operationWaiters.append(continuation)
      }
      return
    }
    operationIsActive = true
  }

  private func releaseOperation() {
    guard !operationWaiters.isEmpty else {
      operationIsActive = false
      return
    }
    operationWaiters.removeFirst().resume()
  }

  private func loadIfNeeded() async throws -> MoriNotificationSnapshot {
    if let cached { return cached }
    let snapshot: MoriNotificationSnapshot
    if let data = try await storage.load() {
      snapshot = try codec.decode(data)
    } else {
      snapshot = MoriNotificationSnapshot()
    }
    cached = snapshot
    return snapshot
  }

  private func persist(_ snapshot: MoriNotificationSnapshot) async throws {
    let data = try codec.encode(snapshot)
    try await storage.save(data)
    cached = snapshot
  }
}
