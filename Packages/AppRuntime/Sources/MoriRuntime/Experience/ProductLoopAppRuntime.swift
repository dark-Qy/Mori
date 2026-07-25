import Foundation
import MoriDomain
import MoriPersistence

public enum ProductLoopAppRuntimeError:
  Error, Equatable, Sendable
{
  case invalidOriginDeviceID
  case profileScopeMismatch
  case missingPassiveEvent(EventID)
}

public enum ProductLoopBootstrapOutcome: Equatable, Sendable {
  case notApplicable
  case ready(
    plannedEventCount: Int,
    newlyPersistedEventCount: Int,
    finalEventCount: Int,
    balance: Int
  )
}

/// Local UI data plus a content-free convergence view.
///
/// This type intentionally does not conform to `Codable`: `localState` may
/// contain health-derived values and narrative content and must remain inside
/// the selected profile namespace.
public struct ProductLoopAppSnapshot: Sendable {
  public let localState: ProfileState
  public let convergenceProjection: ProductLoopProjection

  public init(
    localState: ProfileState,
    convergenceProjection: ProductLoopProjection
  ) {
    self.localState = localState
    self.convergenceProjection = convergenceProjection
  }
}

/// Type erasure keeps transport implementation details out of app stores.
public struct AnyProductLoopExperienceSyncTransport:
  ExperienceSyncTransport, Sendable
{
  private let exchangeClosure: @Sendable (Data) async throws -> Data

  public init<Transport: ExperienceSyncTransport>(
    _ transport: Transport
  ) {
    exchangeClosure = { data in
      try await transport.exchange(data)
    }
  }

  public init(
    exchange:
      @escaping @Sendable (Data) async throws -> Data
  ) {
    exchangeClosure = exchange
  }

  public func exchange(_ transferData: Data) async throws -> Data {
    try await exchangeClosure(transferData)
  }
}

/// File-backed composition root shared by iPhone and Watch app stores.
///
/// The façade owns the repository and outbox concrete types. Presentation code
/// sees only product commands, a sanitized projection, and closed sync bytes;
/// it never mutates `ProfileLedgerRepository` directly.
public actor ProductLoopAppRuntime {
  public nonisolated let profile: RuntimeProfile
  public nonisolated let namespaceRootURL: URL

  private typealias Ledger =
    ProfileLedgerRepository<FileProfileLedgerStorage>
  private typealias SyncRuntime =
    ExperienceSyncRuntime<FileExperienceSyncOutboxStorage, Ledger>

  private let originDeviceID: String
  private let ledger: Ledger
  private let syncRuntime: SyncRuntime
  private let settlementRuntime: TaskSettlementRuntime<SyncRuntime>
  private let collectionRuntime: CollectionMutationRuntime<SyncRuntime>
  private let glanceClock: DeterministicMockExperienceClock
  private let glanceRuntime:
    PendingGlanceRuntime<DeterministicMockExperienceClock>
  #if DEBUG
    private let mockBootstrap: MockProductLoopBootstrap?
  #endif
  private var operationIsActive = false
  private var operationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    applicationSupportURL: URL,
    profile: RuntimeProfile,
    sensing: CompanionSensingPreference,
    originDeviceID: String
  ) throws {
    let origin = originDeviceID.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard origin.isEmpty == false else {
      throw ProductLoopAppRuntimeError.invalidOriginDeviceID
    }
    let layout = try RuntimeStorageLayout(
      applicationSupportURL: applicationSupportURL
    )
    let namespace = try layout.namespace(for: profile)
    try namespace.prepare()
    let initialState = try ProfileInitialStateFactory().make(
      profile: profile,
      sensing: sensing
    )
    let ledger = Ledger(
      storage: namespace.profileLedgerStorage(),
      initialState: initialState
    )
    let syncRuntime = SyncRuntime(
      profile: profile,
      outboxStorage: FileExperienceSyncOutboxStorage(
        fileURL: namespace.url(for: .experienceOutbox)
      ),
      ledger: ledger
    )

    self.profile = profile
    namespaceRootURL = namespace.rootURL
    self.originDeviceID = origin
    self.ledger = ledger
    self.syncRuntime = syncRuntime
    let glanceClock = DeterministicMockExperienceClock(now: Date())
    self.glanceClock = glanceClock
    glanceRuntime = PendingGlanceRuntime(
      clock: glanceClock,
      storage: FilePendingGlancePresentationFenceStorage(
        fileURL: namespace.rootURL
          .appendingPathComponent("cache", isDirectory: true)
          .appendingPathComponent(
            "pending-glance-presentation-fence-v1.json",
            isDirectory: false
          )
      )
    )
    settlementRuntime = TaskSettlementRuntime(
      originDeviceID: origin,
      store: syncRuntime
    )
    collectionRuntime = CollectionMutationRuntime(
      originDeviceID: origin,
      store: syncRuntime
    )
    #if DEBUG
      mockBootstrap =
        profile.isMock ? MockProductLoopBootstrap() : nil
    #endif
  }

  /// Idempotently prepares the selected Mock product loop.
  ///
  /// Real profiles return `notApplicable` without constructing or evaluating
  /// any Mock scenario provider.
  public func bootstrapIfNeeded() async throws
    -> ProductLoopBootstrapOutcome
  {
    await acquireOperation()
    defer { releaseOperation() }
    return try await bootstrapIfNeededUnlocked()
  }

  private func bootstrapIfNeededUnlocked() async throws
    -> ProductLoopBootstrapOutcome
  {
    #if DEBUG
      guard let mockBootstrap else { return .notApplicable }
      let state = (try await ledger.currentReplay()).state
      let result = try await mockBootstrap.bootstrap(
        profile: profile,
        sensing: CompanionSensingPreference(
          enabled: state.companionSensingEnabled,
          epoch: state.currentSensingEpoch
        ),
        store: syncRuntime
      )
      return .ready(
        plannedEventCount: result.plannedEventCount,
        newlyPersistedEventCount:
          result.newlyPersistedEventCount,
        finalEventCount: result.finalEventCount,
        balance: result.balance
      )
    #else
      return .notApplicable
    #endif
  }

  /// Startup/foreground repair with one authoritative UI projection.
  public func activate() async throws -> ProductLoopProjection {
    await acquireOperation()
    defer { releaseOperation() }
    _ = try await bootstrapIfNeededUnlocked()
    _ = try await settlementRuntime.repairIncompleteSettlements()
    return try await projectionUnlocked()
  }

  public func projection() async throws -> ProductLoopProjection {
    await acquireOperation()
    defer { releaseOperation() }
    return try await projectionUnlocked()
  }

  public func snapshot() async throws -> ProductLoopAppSnapshot {
    await acquireOperation()
    defer { releaseOperation() }
    return try await snapshotUnlocked()
  }

  /// Consumes the newest eligible pending event for one foreground activation.
  ///
  /// The profile-scoped presentation fence is committed before a presentation
  /// can escape. Every terminal decision is then recorded through the same
  /// ledger-first, durable-outbox path as the rest of the product loop.
  public func foregroundGlance(
    at date: Date,
    reminderMode: CompanionReminderMode,
    quietHours: CompanionQuietHours,
    timeZone: TimeZone
  ) async throws -> PendingGlancePresentation? {
    await acquireOperation()
    defer { releaseOperation() }

    let current = try await ledger.currentLedger()
    guard current.initialState.runtimeProfile == profile else {
      throw ProductLoopAppRuntimeError.profileScopeMismatch
    }
    let state = current.replay().state
    await glanceClock.set(date)
    let plan = try await glanceRuntime.foregroundActivation(
      events: state.passiveEvents,
      activeProfile: profile,
      currentSensingEpoch: state.currentSensingEpoch,
      reminderMode: reminderMode,
      quietHours: quietHours,
      timeZone: timeZone
    )
    for decision in plan.terminalDecisions {
      guard
        let event = state.passiveEvents.first(where: {
          $0.header.recordID == decision.eventID
        })
      else {
        throw ProductLoopAppRuntimeError.missingPassiveEvent(
          decision.eventID
        )
      }
      try await recordGlanceDecision(
        decision,
        event: event
      )
    }
    return plan.presentation
  }

  private func snapshotUnlocked() async throws
    -> ProductLoopAppSnapshot
  {
    let current = try await ledger.currentLedger()
    guard current.initialState.runtimeProfile == profile else {
      throw ProductLoopAppRuntimeError.profileScopeMismatch
    }
    let state = current.replay().state
    return ProductLoopAppSnapshot(
      localState: state,
      convergenceProjection: ProductLoopProjection(ledger: current)
    )
  }

  private func projectionUnlocked() async throws
    -> ProductLoopProjection
  {
    let current = try await ledger.currentLedger()
    guard current.initialState.runtimeProfile == profile else {
      throw ProductLoopAppRuntimeError.profileScopeMismatch
    }
    return ProductLoopProjection(ledger: current)
  }

  public func completeTask(
    taskID: TaskID,
    method: TaskCompletionMethod,
    at date: Date
  ) async throws -> TaskSettlementResult {
    await acquireOperation()
    defer { releaseOperation() }
    return try await settlementRuntime.complete(
      taskID: taskID,
      method: method,
      at: date
    )
  }

  @discardableResult
  public func repairIncompleteSettlements() async throws
    -> TaskSettlementRepairReport
  {
    await acquireOperation()
    defer { releaseOperation() }
    return try await settlementRuntime.repairIncompleteSettlements()
  }

  public func purchase(
    cosmeticID: CosmeticID,
    operationID: CollectionOperationID = CollectionOperationID(
      rawValue: UUID().uuidString
    ),
    at date: Date
  ) async throws -> CollectionPurchaseMutationResult {
    await acquireOperation()
    defer { releaseOperation() }
    return try await collectionRuntime.purchase(
      cosmeticID: cosmeticID,
      operationID: operationID,
      at: date
    )
  }

  public func equip(
    cosmeticID: CosmeticID,
    operationID: CollectionOperationID = CollectionOperationID(
      rawValue: UUID().uuidString
    ),
    at date: Date
  ) async throws -> CollectionEquipMutationResult {
    await acquireOperation()
    defer { releaseOperation() }
    return try await collectionRuntime.equip(
      cosmeticID: cosmeticID,
      operationID: operationID,
      at: date
    )
  }

  /// Reconciles the ledger baseline with the latest global sensing authority.
  ///
  /// Advancing the epoch expires old pending reminders inside the ledger.
  /// A newly enabled Mock epoch is then seeded through fresh, epoch-scoped
  /// envelopes while the welcome grant and default collection remain exact
  /// duplicates.
  @discardableResult
  public func reconcileSensing(
    _ sensing: CompanionSensingPreference,
    effectiveAt date: Date
  ) async throws -> MutationResult {
    await acquireOperation()
    defer { releaseOperation() }
    let result = try await ledger.setCompanionSensing(
      enabled: sensing.enabled,
      epoch: sensing.epoch,
      effectiveAt: date
    )
    switch result {
    case .applied, .duplicate:
      _ = try await bootstrapIfNeededUnlocked()
    case .rejected:
      break
    }
    return result
  }

  public func receive(_ transferData: Data) async throws -> Data {
    await acquireOperation()
    defer { releaseOperation() }
    let acknowledgement = try await syncRuntime.receive(
      transferData
    )
    _ = try await settlementRuntime.repairIncompleteSettlements()
    return acknowledgement
  }

  public func synchronize(
    using transport: AnyProductLoopExperienceSyncTransport,
    limit: Int = 64
  ) async throws -> ExperienceSyncRunResult {
    await acquireOperation()
    defer { releaseOperation() }
    let result = try await syncRuntime.synchronize(
      using: transport,
      limit: limit
    )
    _ = try await settlementRuntime.repairIncompleteSettlements()
    return result
  }

  public func pendingSyncEventCount() async throws -> Int {
    await acquireOperation()
    defer { releaseOperation() }
    return try await syncRuntime.pendingEventCount()
  }

  private func recordGlanceDecision(
    _ decision: PendingGlanceTerminalDecision,
    event: PassiveCompanionEvent
  ) async throws {
    let current = try await syncRuntime.currentLedger()
    let metadata = try ProductLoopEventSupport.nextMetadata(
      in: current,
      originDeviceID: originDeviceID,
      minimumCounter: event.reminderRevision.counter
    )
    let authoredAt = Self.decisionDate(decision.state)
    let transition = try PendingGlanceTransitionAssembler().assemble(
      decision,
      for: event,
      activeProfile: profile,
      identity: PendingGlanceTransitionIdentity(
        transitionID: EventTransitionID(
          ProductLoopEventSupport.stableID(
            prefix: "glance-transition",
            profile: profile,
            components: [
              decision.eventID.rawValue,
              Self.decisionIdentity(decision.state),
            ]
          )
        ),
        revision: metadata.revision
      )
    )
    let envelope = ProductLoopEventSupport.envelope(
      payload: .passiveEventTransition(transition),
      profile: profile,
      originDeviceID: originDeviceID,
      metadata: metadata,
      observedAt: nil,
      authoredAt: authoredAt
    )
    try await syncRuntime.recordLocal(envelope)
  }

  private static func decisionDate(_ state: ReminderState) -> Date {
    switch state {
    case .pending:
      Date(timeIntervalSince1970: 0)
    case .presented(let date), .expired(let date):
      date
    case .replaced(_, let date):
      date
    }
  }

  private static func decisionIdentity(
    _ state: ReminderState
  ) -> String {
    switch state {
    case .pending:
      "pending"
    case .presented:
      "presented"
    case .expired:
      "expired"
    case .replaced(let eventID, _):
      "replaced-\(eventID.rawValue)"
    }
  }

  private func acquireOperation() async {
    guard operationIsActive == false else {
      await withCheckedContinuation { continuation in
        operationWaiters.append(continuation)
      }
      return
    }
    operationIsActive = true
  }

  private func releaseOperation() {
    guard operationWaiters.isEmpty == false else {
      operationIsActive = false
      return
    }
    operationWaiters.removeFirst().resume()
  }
}
