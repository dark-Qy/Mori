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
  private let glanceRuntime: PendingGlanceRuntime<DeterministicMockExperienceClock>
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

  /// Composes and durably records the iPhone-owned memory for one local day.
  ///
  /// The pure policy enforces the 22:00 release boundary, sensing authority,
  /// eligible evidence, and one-record-per-day identity. Recording uses the
  /// same ledger-first synchronized envelope path as tasks and collections.
  public func composePhoneDailyMemory(
    at date: Date,
    timeZone: TimeZone,
    moments: [SealedMemoryMoment] = []
  ) async throws -> DailyMemoryCompositionOutcome {
    await acquireOperation()
    defer { releaseOperation() }

    #if DEBUG
      if moments.isEmpty == false {
        try await ensureMockDailyMomentEvent(
          at: date,
          timeZone: timeZone,
          moments: moments
        )
      }
    #endif

    let current = try await syncRuntime.currentLedger()
    guard current.initialState.runtimeProfile == profile else {
      throw ProductLoopAppRuntimeError.profileScopeMismatch
    }
    let state = current.replay().state
    let metadata = try ProductLoopEventSupport.nextMetadata(
      in: current,
      originDeviceID: originDeviceID
    )
    let outcome = DailyMemoryCompositionPolicy().compose(
      state: state,
      at: date,
      timeZone: timeZone,
      deviceRole: .iPhone,
      authoredRevision: metadata.revision,
      moments: moments
    )
    guard case .sealed(let memory) = outcome else {
      return outcome
    }
    let envelope = ProductLoopEventSupport.envelope(
      payload: .memory(memory),
      profile: profile,
      originDeviceID: originDeviceID,
      metadata: metadata,
      observedAt: nil,
      authoredAt: date
    )
    try await syncRuntime.recordLocal(envelope)
    return .sealed(memory)
  }

  #if DEBUG
    /// Keeps the daily-moments fixture scoped to the device's current local day.
    /// A stable day-specific fact/event pair makes relaunch idempotent while
    /// allowing the same selected Mock profile to produce tomorrow's memory.
    private func ensureMockDailyMomentEvent(
      at date: Date,
      timeZone: TimeZone,
      moments: [SealedMemoryMoment]
    ) async throws {
      guard
        case .mock(let scenarioID, _) = profile.source,
        scenarioID.rawValue == "mock5",
        moments.isEmpty == false
      else {
        return
      }
      var current = try await syncRuntime.currentLedger()
      var state = current.replay().state
      guard state.companionSensingEnabled else { return }
      let localDay = Self.localDay(for: date, timeZone: timeZone)
      if state.passiveEvents.contains(where: {
        $0.memoryEligibility == .eligible
          && Self.localDay(for: $0.observedAt, timeZone: timeZone) == localDay
      }) {
        return
      }

      let observedAt = date.addingTimeInterval(-30 * 60)
      let factID = EvidenceID(
        ProductLoopEventSupport.stableID(
          prefix: "mock-daily-moment-fact",
          profile: profile,
          components: [localDay.rawValue]
        )
      )
      var fact = state.derivedFacts.first(where: {
        $0.header.recordID == factID
      })
      if fact == nil {
        let record = DerivedFactRecord(
          header: ProfileScopedRecordHeader(
            recordID: factID,
            profileID: profile.id,
            profileEpoch: profile.epoch,
            deletionEpoch: profile.deletionEpoch
          ),
          observedAt: observedAt,
          freshUntil: date.addingTimeInterval(30 * 60),
          value: .foregroundInteraction,
          provenance: .deterministicMock,
          authorization: .companion(state.currentSensingEpoch)
        )
        let metadata = try ProductLoopEventSupport.nextMetadata(
          in: current,
          originDeviceID: originDeviceID
        )
        try await syncRuntime.recordLocal(
          ProductLoopEventSupport.envelope(
            payload: .derivedFact(record),
            profile: profile,
            originDeviceID: originDeviceID,
            metadata: metadata,
            observedAt: record.observedAt,
            authoredAt: date
          )
        )
        fact = record
        current = try await syncRuntime.currentLedger()
        state = current.replay().state
      }
      guard let fact else {
        throw ProductLoopAppRuntimeError.profileScopeMismatch
      }

      let eventID = EventID(
        ProductLoopEventSupport.stableID(
          prefix: "mock-daily-moment-event",
          profile: profile,
          components: [localDay.rawValue]
        )
      )
      guard
        state.passiveEvents.contains(where: {
          $0.header.recordID == eventID
        }) == false
      else {
        return
      }
      let metadata = try ProductLoopEventSupport.nextMetadata(
        in: current,
        originDeviceID: originDeviceID
      )
      let representative = moments.last
      let event = PassiveCompanionEvent(
        header: ProfileScopedRecordHeader(
          recordID: eventID,
          profileID: profile.id,
          profileEpoch: profile.epoch,
          deletionEpoch: profile.deletionEpoch
        ),
        sensingEpoch: state.currentSensingEpoch,
        kind: .foregroundGreeting,
        observedAt: observedAt,
        confidence: .high,
        evidence: [
          EvidenceReference(
            id: fact.header.recordID,
            kind: fact.value.kind
          )
        ],
        presentationDeadline: nil,
        replacementKey: nil,
        taskCooldownKey: nil,
        memoryEligibility: .eligible,
        sceneID: representative?.sceneID ?? "memory.day",
        moriActionID:
          representative?.moriActionID ?? "companion.remember",
        reminderRevision: metadata.revision
      )
      try await syncRuntime.recordLocal(
        ProductLoopEventSupport.envelope(
          payload: .passiveEvent(event),
          profile: profile,
          originDeviceID: originDeviceID,
          metadata: metadata,
          observedAt: event.observedAt,
          authoredAt: date
        )
      )
    }

    private static func localDay(
      for date: Date,
      timeZone: TimeZone
    ) -> LocalDay {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = timeZone
      let components = calendar.dateComponents(
        [.year, .month, .day],
        from: date
      )
      return LocalDay(
        String(
          format: "%04d-%02d-%02d",
          components.year ?? 0,
          components.month ?? 0,
          components.day ?? 0
        )
      )
    }
  #endif

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
