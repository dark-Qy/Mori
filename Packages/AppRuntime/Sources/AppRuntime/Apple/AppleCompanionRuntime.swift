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
    private let health: AppleHealthKitClient
    private let notifications: AppleLocalNotificationClient
    #if DEBUG
      private let mockNotifications: AppleLocalNotificationClient
    #endif
    private let connectivity: AppleWatchConnectivityClient
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

    public init(
      source: EventSource,
      storageDirectory: URL,
      preferencesKey: String = "app.preferences.v1",
      dataSourceKey: String = "app.data-source.v1",
      peerSyncEnabled: Bool = true
    ) {
      self.source = source
      self.peerSyncEnabled = peerSyncEnabled
      health = AppleHealthKitClient()
      notifications = AppleLocalNotificationClient()
      #if DEBUG
        mockNotifications = AppleLocalNotificationClient(
          cooldownStore: UserDefaultsNotificationCooldownStore(
            key: "app.notifications.mock.last-scheduled-date.v1"
          )
        )
      #endif
      connectivity = AppleWatchConnectivityClient()
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
      try await events.currentState()
    }

    public func personalHealthTrend(at date: Date = Date()) async throws -> PersonalHealthTrend {
      let snapshots = try await healthSnapshotHistory()
      return PersonalTrendAnalyzer().analyze(snapshots, at: date)
    }

    /// Read-only canonical daily history for phone-owned personalization. Exact samples remain in
    /// the existing local event ledger and are not copied into personalization storage.
    public func healthSnapshotHistory() async throws -> [Domain.HealthSnapshot] {
      RuntimeHealthSnapshotHistory().snapshots(from: try await events.currentEvents())
    }

    public func refreshHealth(
      now: Date = Date(),
      calendar: Calendar = .current,
      requestAccessIfNeeded: Bool
    ) async throws -> RuntimeHealthRefresh {
      guard await dataSourceSelection.load() == .healthKit else {
        throw CancellationError()
      }
      var localCalendar = calendar
      let timeZone = calendar.timeZone
      localCalendar.timeZone = timeZone
      let dayStart = localCalendar.startOfDay(for: now)
      let sleepStart =
        localCalendar.date(byAdding: .hour, value: -12, to: dayStart)
        ?? dayStart.addingTimeInterval(-12 * 3_600)
      let ingestion = try await HealthIngestionService(client: health, source: source).ingest(
        window: HealthQueryWindow(start: dayStart, sleepStart: sleepStart, end: now),
        timeZone: timeZone,
        requestAccessIfNeeded: requestAccessIfNeeded
      )
      guard await dataSourceSelection.load() == .healthKit else {
        throw CancellationError()
      }
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
      guard await dataSourceSelection.load() == .healthKit else {
        throw CancellationError()
      }
      let notificationDecision = await scheduleProactiveIfAllowed(for: state, now: now)
      await enqueuePeerSync(state, at: now)
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
      let state = try await events.append(
        EventEnvelope(
          eventID: eventID,
          occurredAt: date,
          source: source,
          payload: .petInteracted(PetInteraction(kind: kind))
        )
      )
      await enqueuePeerSync(state, at: date)
      return state
    }

    public func completeTodayMainStory(
      at date: Date = Date(),
      timeZone: TimeZone = .current
    ) async throws -> DailyMainStoryOutcome {
      let outcome = try await events.completeTodayMainStory(
        at: date,
        timeZone: timeZone,
        source: source
      )
      await enqueuePeerSync(outcome.state, at: date)
      return outcome
    }

    public func completeSuggestedHabit(
      at date: Date = Date(),
      timeZone: TimeZone = .current
    ) async throws -> DailyHabitOutcome {
      let current = try await events.currentState()
      let kind = DailyHabitRuleEngine().suggestedHabit(for: current.activeTheme)
      let outcome = try await events.completeDailyHabit(
        kind: kind,
        at: date,
        timeZone: timeZone,
        source: source
      )
      await enqueuePeerSync(outcome.state, at: date)
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
      await dataSourceSelection.save(value)
      do {
        let state = try await events.currentState()
        try await stagePeerSync(state, at: date)
      } catch {
        return .failed(reason: String(describing: error))
      }
      guard peerSyncEnabled else { return .waitingForPeer }
      schedulePeerSyncDrain()
      return .queued
    }

    @discardableResult
    public func savePreferences(_ value: AppPreferences) async throws -> RuntimeSyncStatus {
      try await preferences.save(value)
      do {
        let state = try await events.currentState()
        try await stagePeerSync(state, at: Date())
      } catch {
        return .failed(reason: String(describing: error))
      }
      guard peerSyncEnabled else { return .waitingForPeer }
      schedulePeerSyncDrain()
      return .queued
    }

    public func retryPeerSync(at date: Date = Date()) async throws -> RuntimeSyncStatus {
      guard peerSyncEnabled else { return .waitingForPeer }
      if try await managementOutbox.pendingOperation() == nil {
        let state = try await events.currentState()
        try await stagePeerSync(state, at: date)
      }
      return await drainPeerSyncQueue()
    }

    public func notificationPermissionState() async -> NotificationPermissionState {
      await notifications.permissionState()
    }

    public func requestNotificationPermission() async -> NotificationPermissionState {
      await notifications.requestPermission()
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
      await notifications.cancel(id: "pet.recovery.check-in")
      await notifications.cancel(id: "pet.activity.check-in")
      await notifications.cancel(id: "pet.state-of-mind.check-in")
      await cancelMockCareNotification()
    }

    public func latestPeerState() async -> CompanionSyncState? {
      _ = await connectivity.activate()
      return await connectivity.latestReceivedState()
    }

    public func latestPeerValues() async -> [String: String]? {
      await latestPeerState()?.values
    }

    public func peerValueUpdates() async -> AsyncStream<[String: String]> {
      let states = await connectivity.receivedStates()
      return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let task = Task {
          for await state in states {
            guard !Task.isCancelled else { break }
            continuation.yield(state.values)
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }

    @discardableResult
    public func applyPeerPreferences(_ values: [String: String]) async throws -> Bool {
      let current = try await preferences.load()
      try await preferences.save(
        PeerPreferencesMerger().merge(
          values,
          into: current,
          acceptPhoneOwnedSocialSettings: source == .watch
        )
      )
      if let rawValue = values["dataSource"],
        let selection = CompanionDataSource(rawValue: rawValue)
      {
        return await dataSourceSelection.applyPeerSelection(
          selection,
          token: values["dataSourceSelectionToken"]
        )
      }
      return false
    }

    private func scheduleProactiveIfAllowed(
      for state: CompanionState,
      now: Date
    ) async -> NotificationPolicyDecision? {
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
        saved.proactiveMessagesEnabled,
        saved.proactiveNotificationConsentVersion
          >= AppPreferences.currentNotificationConsentVersion,
        let interaction =
          careInteraction
          ?? ProactiveInteractionPlanner().plan(for: state, now: now)
      else { return nil }
      let permission = await notifications.permissionState()
      guard permission == .authorized || permission == .provisional || permission == .ephemeral
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

    private func send(_ operation: ManagementSyncOperation) async -> RuntimeSyncStatus {
      let activation = await connectivity.activate()
      switch activation {
      case .inactive:
        return .waitingForPeer
      case .unavailable(let reason):
        return .unavailable(reason: reason)
      case .activated:
        break
      }

      do {
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

    private func stagePeerSync(_ state: CompanionState, at date: Date) async throws {
      let savedPreferences = try? await preferences.load()
      let selectedDataSource = await dataSourceSelection.load()
      let dataSourceSelectionToken = await dataSourceSelection.loadSelectionToken()
      let values = PeerStateProjection().makeValues(
        companion: state,
        preferences: savedPreferences,
        dataSource: selectedDataSource,
        dataSourceSelectionToken: dataSourceSelectionToken,
        includePhoneOwnedSocialSettings: source == .phone
      )
      try await managementOutbox.enqueue(values: values, updatedAt: date)
    }

    /// Local progression must never wait for a paired device. The durable outbox coalesces to the
    /// newest management state and survives process termination until transport accepts it.
    private func enqueuePeerSync(_ state: CompanionState, at date: Date) async {
      do {
        try await stagePeerSync(state, at: date)
      } catch {
        return
      }
      guard peerSyncEnabled else { return }
      schedulePeerSyncDrain()
    }

    private func schedulePeerSyncDrain() {
      guard peerSyncTask == nil else { return }
      peerSyncTask = Task { [weak self] in
        _ = await self?.drainPeerSyncQueue()
      }
    }

    private func drainPeerSyncQueue() async -> RuntimeSyncStatus {
      defer { peerSyncTask = nil }
      guard peerSyncEnabled else { return .waitingForPeer }
      while true {
        let operation: ManagementSyncOperation
        do {
          guard let pending = try await managementOutbox.pendingOperation() else {
            return .synced
          }
          operation = pending
        } catch {
          return .failed(reason: String(describing: error))
        }
        let status = await send(operation)
        guard status == .synced else { return status }
        do {
          try await managementOutbox.acknowledge(revision: operation.revision)
        } catch {
          return .failed(reason: String(describing: error))
        }
      }
    }
  }
#endif
