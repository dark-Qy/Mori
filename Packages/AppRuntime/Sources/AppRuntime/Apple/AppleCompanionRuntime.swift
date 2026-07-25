#if canImport(HealthKit) && canImport(UserNotifications) && canImport(WatchConnectivity)
  import AppleAdapters
  import Domain
  import Foundation
  import Persistence
  import Rules

  public enum RuntimeSyncStatus: Equatable, Sendable {
    case synced
    case queued
    case waitingForPeer
    case unavailable(reason: String)
    case failed(reason: String)
  }

  public enum RuntimeNotificationPermissionStatus: Equatable, Sendable {
    case notRequested
    case allowed
    case denied
    case unavailable
  }

  public enum RuntimeNotificationScheduleStatus: Equatable, Sendable {
    case scheduled
    case alreadyScheduled
    case denied
    case unavailable
    case failed
  }

  public struct RuntimeHealthRefresh: Sendable {
    public let requestState: HealthAccessRequestState
    public let health: Domain.HealthSnapshot
    public let companion: CompanionState
    public let notificationDecision: NotificationPolicyDecision?
    public let syncStatus: RuntimeSyncStatus

    public init(
      requestState: HealthAccessRequestState,
      health: Domain.HealthSnapshot,
      companion: CompanionState,
      notificationDecision: NotificationPolicyDecision?,
      syncStatus: RuntimeSyncStatus
    ) {
      self.requestState = requestState
      self.health = health
      self.companion = companion
      self.notificationDecision = notificationDecision
      self.syncStatus = syncStatus
    }
  }

  /// Production composition root for iOS and watchOS. Tests use the individual mockable services;
  /// this type deliberately contains no presentation logic.
  public actor AppleCompanionRuntime {
    private let source: EventSource
    private var health: AppleHealthKitClient?
    private var notifications: AppleLocalNotificationClient?
    private var connectivity: AppleWatchConnectivityClient?
    #if DEBUG
      private let mockNotifications: AppleLocalNotificationClient
    #endif
    private let events: CompanionEventEngine<FileEventLedgerStorage>
    private let preferences: PreferencesRepository<UserDefaultsPreferencesDataStore>
    private let dataSourceSelection: DataSourceSelectionRepository
    private let managementOutbox: ManagementSyncOutbox<FileManagementSyncOutboxStorage>
    private let peerSyncEnabled: Bool
    private var peerSyncTask: Task<Void, Never>?
    private var careScheduleInFlight: Set<UUID> = []
    #if DEBUG
      private var mockCareScheduleGeneration: UInt64 = 0
    #endif
    private var selectionGeneration: UInt64 = 0
    private var selectionTransitionTarget: CompanionDataSource?
    private var productionMutationIsActive = false
    private var productionMutationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
      source: EventSource,
      storageDirectory: URL,
      preferencesKey: String = "app.preferences.v1",
      dataSourceKey: String = "app.data-source.v1",
      peerSyncEnabled: Bool = true
    ) {
      self.source = source
      self.peerSyncEnabled = peerSyncEnabled
      #if DEBUG
        mockNotifications = AppleLocalNotificationClient(
          cooldownStore: UserDefaultsNotificationCooldownStore(
            key: "app.notifications.mock.last-scheduled-date.v1"
          )
        )
      #endif
      events = CompanionEventEngine(
        storage: FileEventLedgerStorage(
          fileURL: storageDirectory.appendingPathComponent("event-ledger-v1.json")
        )
      )
      preferences = PreferencesRepository(
        store: UserDefaultsPreferencesDataStore(key: preferencesKey)
      )
      dataSourceSelection = DataSourceSelectionRepository(key: dataSourceKey)
      managementOutbox = ManagementSyncOutbox(
        storage: FileManagementSyncOutboxStorage(
          fileURL: storageDirectory.appendingPathComponent("management-sync-outbox-v1.json")
        )
      )
    }

    public func currentState() async throws -> CompanionState {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      let generation = try await requireProductionProfile()
      let state = try await events.currentState()
      try await requireProductionProfile(generation: generation)
      return state
    }

    public func personalHealthTrend(at date: Date = Date()) async throws -> PersonalHealthTrend {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      let generation = try await requireProductionProfile()
      let snapshots: [Domain.HealthSnapshot] = try await events.currentEvents().compactMap {
        event -> Domain.HealthSnapshot? in
        guard case .healthSnapshotReceived(let snapshot) = event.payload else { return nil }
        return snapshot
      }
      try await requireProductionProfile(generation: generation)
      return PersonalTrendAnalyzer().analyze(snapshots, at: date)
    }

    /// Read-only canonical daily history for phone-owned personalization. Exact samples remain in
    /// the existing local event ledger and are not copied into personalization storage.
    public func healthSnapshotHistory() async throws -> [Domain.HealthSnapshot] {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      let generation = try await requireProductionProfile()
      let snapshots = RuntimeHealthSnapshotHistory().snapshots(
        from: try await events.currentEvents()
      )
      try await requireProductionProfile(generation: generation)
      return snapshots
    }

    public func refreshHealth(
      now: Date = Date(),
      calendar: Calendar = .current,
      requestAccessIfNeeded: Bool
    ) async throws -> RuntimeHealthRefresh {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      let generation = try await requireProductionProfile()
      var localCalendar = calendar
      let timeZone = calendar.timeZone
      localCalendar.timeZone = timeZone
      let dayStart = localCalendar.startOfDay(for: now)
      let sleepStart =
        localCalendar.date(byAdding: .hour, value: -12, to: dayStart)
        ?? dayStart.addingTimeInterval(-12 * 3_600)
      let ingestion = try await HealthIngestionService(
        client: healthClient(),
        source: source
      ).ingest(
        window: HealthQueryWindow(start: dayStart, sleepStart: sleepStart, end: now),
        timeZone: timeZone,
        requestAccessIfNeeded: requestAccessIfNeeded
      )
      try await requireProductionProfile(generation: generation)
      var state = try await events.append(ingestion.event)
      let soccerOutcome = try await events.evaluateSoccerSideStory(
        snapshot: ingestion.snapshot,
        triggerEventID: ingestion.event.eventID,
        at: now,
        source: source
      )
      if case .unlocked(let unlockedState) = soccerOutcome {
        state = unlockedState
      }
      try await requireProductionProfile(generation: generation)
      let notificationDecision = await scheduleProactiveIfAllowed(
        for: state,
        now: now,
        generation: generation
      )
      try await requireProductionProfile(generation: generation)
      await enqueuePeerSync(state, at: now, generation: generation)
      try await requireProductionProfile(generation: generation)
      return RuntimeHealthRefresh(
        requestState: ingestion.requestState,
        health: ingestion.snapshot,
        companion: state,
        notificationDecision: notificationDecision,
        syncStatus: .queued
      )
    }

    public func recordPetInteraction(
      kind: String,
      at date: Date = Date(),
      eventID: UUID = UUID()
    ) async throws -> CompanionState {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      let generation = try await requireProductionProfile()
      let state = try await events.append(
        EventEnvelope(
          eventID: eventID,
          occurredAt: date,
          source: source,
          payload: .petInteracted(PetInteraction(kind: kind))
        )
      )
      try await requireProductionProfile(generation: generation)
      await enqueuePeerSync(state, at: date, generation: generation)
      try await requireProductionProfile(generation: generation)
      return state
    }

    public func completeTodayMainStory(
      at date: Date = Date(),
      timeZone: TimeZone = .current
    ) async throws -> DailyMainStoryOutcome {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      let generation = try await requireProductionProfile()
      let outcome = try await events.completeTodayMainStory(
        at: date,
        timeZone: timeZone,
        source: source
      )
      try await requireProductionProfile(generation: generation)
      await enqueuePeerSync(outcome.state, at: date, generation: generation)
      try await requireProductionProfile(generation: generation)
      return outcome
    }

    public func completeSuggestedHabit(
      at date: Date = Date(),
      timeZone: TimeZone = .current
    ) async throws -> DailyHabitOutcome {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      let generation = try await requireProductionProfile()
      let current = try await events.currentState()
      try await requireProductionProfile(generation: generation)
      let kind = DailyHabitRuleEngine().suggestedHabit(for: current.activeTheme)
      let outcome = try await events.completeDailyHabit(
        kind: kind,
        at: date,
        timeZone: timeZone,
        source: source
      )
      try await requireProductionProfile(generation: generation)
      await enqueuePeerSync(outcome.state, at: date, generation: generation)
      try await requireProductionProfile(generation: generation)
      return outcome
    }

    public func loadPreferences() async throws -> AppPreferences {
      try await preferences.load()
    }

    public func loadDataSourceSelection() async -> CompanionDataSource {
      await dataSourceSelection.load()
    }

    @discardableResult
    public func saveDataSourceSelection(
      _ value: CompanionDataSource,
      at date: Date = Date()
    ) async -> RuntimeSyncStatus {
      await acquireProductionMutation()
      selectionGeneration &+= 1
      let generation = selectionGeneration
      selectionTransitionTarget = value
      defer {
        releaseProductionMutation()
        if generation == selectionGeneration {
          selectionTransitionTarget = nil
        }
      }
      peerSyncTask?.cancel()
      peerSyncTask = nil
      let previous = await dataSourceSelection.load()
      guard generation == selectionGeneration else { return .waitingForPeer }
      if previous == .healthKit, value != .healthKit {
        let notifications = notificationClient()
        await notifications.cancelAll()
        guard generation == selectionGeneration else { return .waitingForPeer }
      }
      await dataSourceSelection.save(value)
      guard generation == selectionGeneration else {
        return .waitingForPeer
      }
      selectionTransitionTarget = nil
      guard value == .healthKit else { return .waitingForPeer }
      do {
        let state = try await events.currentState()
        try await requireProductionProfile(generation: generation)
        try await stagePeerSync(state, at: date, generation: generation)
      } catch {
        return .failed(reason: String(describing: error))
      }
      guard peerSyncEnabled else { return .waitingForPeer }
      schedulePeerSyncDrain(generation: generation)
      return .queued
    }

    @discardableResult
    public func savePreferences(_ value: AppPreferences) async throws -> RuntimeSyncStatus {
      try await preferences.save(value)
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      guard let generation = await productionGeneration() else {
        return .waitingForPeer
      }
      do {
        let state = try await events.currentState()
        try await requireProductionProfile(generation: generation)
        try await stagePeerSync(state, at: Date(), generation: generation)
      } catch {
        return .failed(reason: String(describing: error))
      }
      guard peerSyncEnabled else { return .waitingForPeer }
      schedulePeerSyncDrain(generation: generation)
      return .queued
    }

    public func retryPeerSync(at date: Date = Date()) async throws -> RuntimeSyncStatus {
      await acquireProductionMutation()
      guard peerSyncEnabled, let generation = await productionGeneration() else {
        releaseProductionMutation()
        return .waitingForPeer
      }
      do {
        if try await managementOutbox.pendingOperation() == nil {
          try await requireProductionProfile(generation: generation)
          let state = try await events.currentState()
          try await requireProductionProfile(generation: generation)
          try await stagePeerSync(state, at: date, generation: generation)
        }
      } catch {
        releaseProductionMutation()
        throw error
      }
      releaseProductionMutation()
      return await drainPeerSyncQueue(generation: generation)
    }

    public func notificationPermissionState() async -> NotificationPermissionState {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      guard let generation = await productionGeneration() else {
        return NotificationPermissionState.unavailable(
          reason: "Notifications are unavailable in Mock data mode."
        )
      }
      let state = await notificationClient().permissionState()
      guard await isCurrentProductionGeneration(generation) else {
        return NotificationPermissionState.unavailable(
          reason: "Notifications are unavailable in Mock data mode."
        )
      }
      return state
    }

    public func requestNotificationPermission() async -> NotificationPermissionState {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      guard let generation = await productionGeneration() else {
        return NotificationPermissionState.unavailable(
          reason: "Notifications are unavailable in Mock data mode."
        )
      }
      let state = await notificationClient().requestPermission()
      guard await isCurrentProductionGeneration(generation) else {
        return NotificationPermissionState.unavailable(
          reason: "Notifications are unavailable in Mock data mode."
        )
      }
      return state
    }

    public func notificationPermissionStatus() async -> RuntimeNotificationPermissionStatus {
      Self.mapNotificationPermission(await notificationPermissionState())
    }

    public func requestNotificationPermissionStatus() async -> RuntimeNotificationPermissionStatus {
      Self.mapNotificationPermission(await requestNotificationPermission())
    }

    public func scheduleMockCareNotification(
      after delay: TimeInterval = 60,
      now: Date = Date()
    ) async -> RuntimeNotificationScheduleStatus {
      #if DEBUG
        guard let selectionToken = await dataSourceSelection.mockCareNotificationTokenIfNeeded()
        else {
          return .alreadyScheduled
        }
        mockCareScheduleGeneration &+= 1
        let generation = mockCareScheduleGeneration
        let notificationID = "mock.pet.state-of-mind.check-in.\(selectionToken)"
        var permission = await mockNotifications.permissionState()
        if permission == .notRequested {
          permission = await mockNotifications.requestPermission()
        }
        guard
          generation == mockCareScheduleGeneration,
          await dataSourceSelection.mockCareNotificationTokenIfNeeded() == selectionToken
        else { return .failed }
        switch permission {
        case .authorized, .provisional, .ephemeral:
          break
        case .denied:
          return .denied
        case .notRequested, .unavailable:
          return .unavailable
        }

        let interaction = ApprovedProactiveInteraction(
          id: notificationID,
          title: "Mock 2 · Mori 想陪你待一会",
          body: "模拟来信：不用解释，要不要和我安静待一会儿？",
          fireDate: now.addingTimeInterval(max(1, delay)),
          route: "pet/care",
          interruptionLevel: .timeSensitive
        )
        do {
          let decision = try await ProactiveInteractionService(client: mockNotifications).schedule(
            interaction,
            policy: NotificationPolicy()
          )
          guard decision == .allow else { return .failed }
          guard
            generation == mockCareScheduleGeneration,
            await dataSourceSelection.markMockCareNotificationScheduled(
              selectionToken: selectionToken
            )
          else {
            await mockNotifications.cancelAndRemoveDelivered(id: notificationID)
            return .failed
          }
          return .scheduled
        } catch {
          return .failed
        }
      #else
        return .unavailable
      #endif
    }

    public func cancelMockCareNotification() async {
      #if DEBUG
        mockCareScheduleGeneration &+= 1
        if let selectionToken =
          await dataSourceSelection.lastScheduledMockCareNotificationToken()
        {
          await mockNotifications.cancelAndRemoveDelivered(
            id: "mock.pet.state-of-mind.check-in.\(selectionToken)"
          )
        }
      #endif
    }

    public func cancelProactiveNotifications() async {
      await cancelMockCareNotification()
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      guard let generation = await productionGeneration() else { return }
      let client = notificationClient()
      await client.cancel(id: "pet.recovery.check-in")
      guard await isCurrentProductionGeneration(generation) else { return }
      await client.cancel(id: "pet.activity.check-in")
      guard await isCurrentProductionGeneration(generation) else { return }
      await client.cancel(id: "pet.state-of-mind.check-in")
    }

    /// Clears every app-owned local store currently composed by this runtime.
    ///
    /// A higher-level deletion coordinator must persist the global deletion
    /// fence before calling this method. HealthKit records and Apple permission
    /// choices are system-owned and intentionally remain untouched.
    public func deleteAllLocalData() async throws {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }

      selectionGeneration &+= 1
      selectionTransitionTarget = nil
      peerSyncTask?.cancel()
      peerSyncTask = nil
      careScheduleInFlight.removeAll()

      #if DEBUG
        mockCareScheduleGeneration &+= 1
        await mockNotifications.cancelAll()
      #endif
      await notificationClient().cancelAll()
      _ = try await events.replace(with: [])
      try await preferences.save(AppPreferences())
      await dataSourceSelection.clearForDeletion()
      try await managementOutbox.clearForDeletion()

      health = nil
      notifications = nil
      connectivity = nil
    }

    public func latestPeerState() async -> CompanionSyncState? {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      guard let generation = await productionGeneration() else { return nil }
      let connectivity = connectivityClient()
      _ = await connectivity.activate()
      guard await isCurrentProductionGeneration(generation) else { return nil }
      let state = await connectivity.latestReceivedState()
      guard await isCurrentProductionGeneration(generation) else { return nil }
      return state
    }

    public func latestPeerValues() async -> [String: String]? {
      await latestPeerState()?.values
    }

    public func peerValueUpdates() async -> AsyncStream<[String: String]> {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      guard let generation = await productionGeneration() else {
        return AsyncStream { $0.finish() }
      }
      let states = await connectivityClient().receivedStates()
      guard await isCurrentProductionGeneration(generation) else {
        return AsyncStream { $0.finish() }
      }
      return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let task = Task { [weak self] in
          for await state in states {
            guard
              !Task.isCancelled,
              let self,
              await self.isCurrentProductionGeneration(generation)
            else { break }
            continuation.yield(state.values)
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }

    @discardableResult
    public func applyPeerPreferences(_ values: [String: String]) async throws -> Bool {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      let incomingSelection =
        values["dataSource"].flatMap(CompanionDataSource.init(rawValue:))
      let selectionPlan: PeerDataSourceSelectionPlan? =
        if let incomingSelection {
          await dataSourceSelection.preparePeerSelection(
            incomingSelection,
            token: values["dataSourceSelectionToken"]
          )
        } else {
          nil
        }
      let changesMode = selectionPlan?.changesMode == true
      let transitionGeneration: UInt64?
      if changesMode {
        selectionGeneration &+= 1
        transitionGeneration = selectionGeneration
        selectionTransitionTarget = incomingSelection
        peerSyncTask?.cancel()
        peerSyncTask = nil
      } else {
        transitionGeneration = nil
      }
      defer {
        if let transitionGeneration,
          transitionGeneration == selectionGeneration
        {
          selectionTransitionTarget = nil
        }
      }
      let current = try await preferences.load()
      try await preferences.save(
        PeerPreferencesMerger().merge(
          values,
          into: current,
          acceptPhoneOwnedSocialSettings: source == .watch
        )
      )
      if let selectionPlan {
        if let transitionGeneration {
          guard transitionGeneration == selectionGeneration else { return false }
        }
        if selectionPlan.leavesProduction {
          let notifications = notificationClient()
          await notifications.cancelAll()
          if let transitionGeneration {
            guard transitionGeneration == selectionGeneration else { return false }
          }
        }
        let applied = await dataSourceSelection.commitPeerSelection(selectionPlan)
        if let transitionGeneration,
          transitionGeneration == selectionGeneration
        {
          selectionTransitionTarget = nil
        }
        return applied
      }
      return false
    }

    private func scheduleProactiveIfAllowed(
      for state: CompanionState,
      now: Date,
      generation: UInt64
    ) async -> NotificationPolicyDecision? {
      guard await isCurrentProductionGeneration(generation) else { return nil }
      let careInteraction = CareCheckInPlanner().plan(for: state, now: now)
      let careSampleID = careInteraction == nil ? nil : state.lastStateOfMind?.id
      if let careSampleID {
        guard careScheduleInFlight.insert(careSampleID).inserted else { return nil }
      }
      defer {
        if let careSampleID {
          careScheduleInFlight.remove(careSampleID)
        }
      }
      guard
        let saved = try? await preferences.load(),
        await isCurrentProductionGeneration(generation),
        saved.proactiveMessagesEnabled,
        saved.proactiveNotificationConsentVersion
          >= AppPreferences.currentNotificationConsentVersion,
        let interaction =
          careInteraction
          ?? ProactiveInteractionPlanner().plan(for: state, now: now)
      else { return nil }
      let notifications = notificationClient()
      let permission = await notifications.permissionState()
      guard
        await isCurrentProductionGeneration(generation),
        permission == .authorized || permission == .provisional || permission == .ephemeral
      else { return nil }
      let decision = try? await ProactiveInteractionService(client: notifications).schedule(
        interaction,
        policy: NotificationPolicy(
          quietHours: QuietHours(
            startMinute: saved.quietHoursStartMinute,
            endMinute: saved.quietHoursEndMinute
          ),
          minimumCooldown: 4 * 3_600
        )
      )
      guard await isCurrentProductionGeneration(generation) else {
        await notifications.cancel(id: interaction.id)
        return nil
      }
      if decision == .allow, let careSampleID {
        _ = try? await events.append(
          EventEnvelope(
            eventID: UUID(),
            occurredAt: now,
            source: source,
            payload: .stateOfMindCareScheduled(
              StateOfMindCareSchedule(sampleID: careSampleID)
            )
          )
        )
        guard await isCurrentProductionGeneration(generation) else {
          await notifications.cancel(id: interaction.id)
          return nil
        }
      }
      return decision
    }

    private static func mapNotificationPermission(
      _ status: NotificationPermissionState
    ) -> RuntimeNotificationPermissionStatus {
      switch status {
      case .notRequested: .notRequested
      case .authorized, .provisional, .ephemeral: .allowed
      case .denied: .denied
      case .unavailable: .unavailable
      }
    }

    private func send(
      _ operation: ManagementSyncOperation,
      generation: UInt64
    ) async -> RuntimeSyncStatus {
      guard await isCurrentProductionGeneration(generation) else {
        return .waitingForPeer
      }
      let connectivity = connectivityClient()
      let activation = await connectivity.activate()
      guard await isCurrentProductionGeneration(generation) else {
        return .waitingForPeer
      }
      switch activation {
      case .inactive:
        return .waitingForPeer
      case .unavailable(let reason):
        return .unavailable(reason: reason)
      case .activated:
        break
      }

      do {
        guard await isCurrentProductionGeneration(generation) else {
          return .waitingForPeer
        }
        try await connectivity.send(
          CompanionSyncState(
            revision: operation.revision,
            updatedAt: operation.updatedAt,
            values: operation.values
          )
        )
        return .synced
      } catch {
        return .failed(reason: String(describing: error))
      }
    }

    private func stagePeerSync(
      _ state: CompanionState,
      at date: Date,
      generation: UInt64
    ) async throws {
      try await requireProductionProfile(generation: generation)
      let savedPreferences = try? await preferences.load()
      try await requireProductionProfile(generation: generation)
      let selectedDataSource = await dataSourceSelection.load()
      let dataSourceSelectionToken = await dataSourceSelection.loadSelectionToken()
      try await requireProductionProfile(generation: generation)
      let values = PeerStateProjection().makeValues(
        companion: state,
        preferences: savedPreferences,
        dataSource: selectedDataSource,
        dataSourceSelectionToken: dataSourceSelectionToken,
        includePhoneOwnedSocialSettings: source == .phone
      )
      try await managementOutbox.enqueue(values: values, updatedAt: date)
      try await requireProductionProfile(generation: generation)
    }

    private func productionGeneration() async -> UInt64? {
      let generation = selectionGeneration
      guard await isCurrentProductionGeneration(generation) else { return nil }
      return generation
    }

    private func acquireProductionMutation() async {
      guard productionMutationIsActive else {
        productionMutationIsActive = true
        return
      }
      await withCheckedContinuation { continuation in
        productionMutationWaiters.append(continuation)
      }
    }

    private func releaseProductionMutation() {
      guard !productionMutationWaiters.isEmpty else {
        productionMutationIsActive = false
        return
      }
      productionMutationWaiters.removeFirst().resume()
    }

    private func isCurrentProductionGeneration(_ generation: UInt64) async -> Bool {
      guard
        generation == selectionGeneration,
        selectionTransitionTarget == nil
      else { return false }
      let selection = await dataSourceSelection.load()
      return
        generation == selectionGeneration
        && selectionTransitionTarget == nil
        && selection == .healthKit
    }

    @discardableResult
    private func requireProductionProfile() async throws -> UInt64 {
      guard let generation = await productionGeneration() else {
        throw CancellationError()
      }
      return generation
    }

    private func requireProductionProfile(generation: UInt64) async throws {
      guard await isCurrentProductionGeneration(generation) else {
        throw CancellationError()
      }
    }

    private func healthClient() -> AppleHealthKitClient {
      if let health { return health }
      let client = AppleHealthKitClient()
      health = client
      return client
    }

    private func notificationClient() -> AppleLocalNotificationClient {
      if let notifications { return notifications }
      let client = AppleLocalNotificationClient()
      notifications = client
      return client
    }

    private func connectivityClient() -> AppleWatchConnectivityClient {
      if let connectivity { return connectivity }
      let client = AppleWatchConnectivityClient()
      connectivity = client
      return client
    }

    /// Local progression must never wait for a paired device. The durable outbox coalesces to the
    /// newest management state and survives process termination until transport accepts it.
    private func enqueuePeerSync(
      _ state: CompanionState,
      at date: Date,
      generation: UInt64
    ) async {
      do {
        try await stagePeerSync(state, at: date, generation: generation)
      } catch {
        return
      }
      guard
        peerSyncEnabled,
        await isCurrentProductionGeneration(generation)
      else { return }
      schedulePeerSyncDrain(generation: generation)
    }

    private func schedulePeerSyncDrain(generation: UInt64) {
      guard peerSyncTask == nil else { return }
      peerSyncTask = Task { [weak self] in
        _ = await self?.drainPeerSyncQueue(generation: generation)
      }
    }

    private func drainPeerSyncQueue(generation: UInt64) async -> RuntimeSyncStatus {
      await acquireProductionMutation()
      defer { releaseProductionMutation() }
      defer {
        if generation == selectionGeneration {
          peerSyncTask = nil
        }
      }
      guard
        peerSyncEnabled,
        !Task.isCancelled,
        await isCurrentProductionGeneration(generation)
      else { return .waitingForPeer }
      while true {
        guard
          !Task.isCancelled,
          await isCurrentProductionGeneration(generation)
        else { return .waitingForPeer }
        let operation: ManagementSyncOperation
        do {
          guard let pending = try await managementOutbox.pendingOperation() else {
            return .synced
          }
          operation = pending
        } catch {
          return .failed(reason: String(describing: error))
        }
        let status = await send(operation, generation: generation)
        guard status == .synced else { return status }
        guard
          !Task.isCancelled,
          await isCurrentProductionGeneration(generation)
        else { return .waitingForPeer }
        do {
          try await managementOutbox.acknowledge(revision: operation.revision)
        } catch {
          return .failed(reason: String(describing: error))
        }
      }
    }
  }
#endif
