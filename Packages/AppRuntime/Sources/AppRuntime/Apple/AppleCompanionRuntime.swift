#if canImport(HealthKit) && canImport(UserNotifications) && canImport(WatchConnectivity)
  import AppleAdapters
  import Domain
  import Foundation
  import Persistence
  import Rules

  public enum RuntimeSyncStatus: Equatable, Sendable {
    case synced
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
    private let connectivity: AppleWatchConnectivityClient
    private let events: CompanionEventEngine<FileEventLedgerStorage>
    private let preferences: PreferencesRepository<UserDefaultsPreferencesDataStore>
    private var lastSyncRevision: UInt64 = 0

    public init(
      source: EventSource,
      storageDirectory: URL,
      preferencesKey: String = "app.preferences.v1"
    ) {
      self.source = source
      health = AppleHealthKitClient()
      notifications = AppleLocalNotificationClient()
      connectivity = AppleWatchConnectivityClient()
      events = CompanionEventEngine(
        storage: FileEventLedgerStorage(
          fileURL: storageDirectory.appendingPathComponent("event-ledger-v1.json")
        )
      )
      preferences = PreferencesRepository(
        store: UserDefaultsPreferencesDataStore(key: preferencesKey)
      )
    }

    public func currentState() async throws -> CompanionState {
      try await events.currentState()
    }

    public func personalHealthTrend(at date: Date = Date()) async throws -> PersonalHealthTrend {
      let snapshots: [Domain.HealthSnapshot] = try await events.currentEvents().compactMap {
        event -> Domain.HealthSnapshot? in
        guard case .healthSnapshotReceived(let snapshot) = event.payload else { return nil }
        return snapshot
      }
      return PersonalTrendAnalyzer().analyze(snapshots, at: date)
    }

    public func refreshHealth(
      now: Date = Date(),
      calendar: Calendar = .current,
      requestAccessIfNeeded: Bool
    ) async throws -> RuntimeHealthRefresh {
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
      let notificationDecision = await scheduleProactiveIfAllowed(for: state, now: now)
      let syncStatus = await sendDerivedState(state, at: now)
      return RuntimeHealthRefresh(
        requestState: ingestion.requestState,
        health: ingestion.snapshot,
        companion: state,
        notificationDecision: notificationDecision,
        syncStatus: syncStatus
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
      _ = await sendDerivedState(state, at: date)
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
      _ = await sendDerivedState(outcome.state, at: date)
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
      _ = await sendDerivedState(outcome.state, at: date)
      return outcome
    }

    public func loadPreferences() async throws -> AppPreferences {
      try await preferences.load()
    }

    public func savePreferences(_ value: AppPreferences) async throws {
      try await preferences.save(value)
      let state = try await events.currentState()
      _ = await sendDerivedState(state, at: Date())
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

    public func cancelProactiveNotifications() async {
      await notifications.cancel(id: "pet.recovery.check-in")
      await notifications.cancel(id: "pet.activity.check-in")
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

    public func applyPeerPreferences(_ values: [String: String]) async throws {
      var current = try await preferences.load()
      if let enabled = values["proactiveMessagesEnabled"].flatMap(Bool.init) {
        current.proactiveMessagesEnabled = enabled
      }
      if let consentVersion = values["proactiveNotificationConsentVersion"].flatMap(Int.init) {
        current.proactiveNotificationConsentVersion = consentVersion
      }
      if let quietStart = values["quietHoursStartMinute"].flatMap(Int.init) {
        current.quietHoursStartMinute = max(0, min(1_439, quietStart))
      }
      if let quietEnd = values["quietHoursEndMinute"].flatMap(Int.init) {
        current.quietHoursEndMinute = max(0, min(1_439, quietEnd))
      }
      try await preferences.save(current)
    }

    private func scheduleProactiveIfAllowed(
      for state: CompanionState,
      now: Date
    ) async -> NotificationPolicyDecision? {
      guard
        let saved = try? await preferences.load(),
        saved.proactiveMessagesEnabled,
        saved.proactiveNotificationConsentVersion
          >= AppPreferences.currentNotificationConsentVersion,
        let interaction = ProactiveInteractionPlanner().plan(for: state, now: now)
      else { return nil }
      let permission = await notifications.permissionState()
      guard permission == .authorized || permission == .provisional || permission == .ephemeral
      else { return nil }
      return try? await ProactiveInteractionService(client: notifications).schedule(
        interaction,
        policy: NotificationPolicy(
          quietHours: QuietHours(
            startMinute: saved.quietHoursStartMinute,
            endMinute: saved.quietHoursEndMinute
          ),
          minimumCooldown: 4 * 3_600
        )
      )
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

    private func sendDerivedState(_ state: CompanionState, at date: Date) async
      -> RuntimeSyncStatus
    {
      let activation = await connectivity.activate()
      switch activation {
      case .inactive:
        return .waitingForPeer
      case .unavailable(let reason):
        return .unavailable(reason: reason)
      case .activated:
        break
      }

      let clockRevision = UInt64(max(0, date.timeIntervalSince1970 * 1_000))
      let revision = max(lastSyncRevision &+ 1, clockRevision)
      let selectedOutfitID =
        (try? await preferences.load().selectedOutfitID)
        ?? state.pet.equippedOutfitID
        ?? "default"
      let savedPreferences = try? await preferences.load()
      do {
        try await connectivity.send(
          CompanionSyncState(
            revision: revision,
            updatedAt: date,
            values: [
              "name": state.pet.name,
              "mood": state.pet.mood.rawValue,
              "theme": state.activeTheme.rawValue,
              "vitality": String(state.growth.vitality),
              "chapter": String(state.story.mainlineChapter),
              "outfit": selectedOutfitID,
              "proactiveMessagesEnabled": String(
                savedPreferences?.proactiveMessagesEnabled ?? false),
              "proactiveNotificationConsentVersion": String(
                savedPreferences?.proactiveNotificationConsentVersion ?? 0),
              "quietHoursStartMinute": String(
                savedPreferences?.quietHoursStartMinute ?? 1_320),
              "quietHoursEndMinute": String(savedPreferences?.quietHoursEndMinute ?? 420),
            ]
          )
        )
        lastSyncRevision = revision
        return .synced
      } catch {
        return .failed(reason: String(describing: error))
      }
    }
  }
#endif
