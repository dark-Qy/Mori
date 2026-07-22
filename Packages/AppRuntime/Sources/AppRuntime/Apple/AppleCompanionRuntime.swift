#if canImport(HealthKit) && canImport(UserNotifications) && canImport(WatchConnectivity)
  import AppleAdapters
  import Domain
  import Foundation
  import Persistence

  public enum RuntimeSyncStatus: Equatable, Sendable {
    case synced
    case waitingForPeer
    case unavailable(reason: String)
    case failed(reason: String)
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
      let state = try await events.append(ingestion.event)
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

    public func loadPreferences() async throws -> AppPreferences {
      try await preferences.load()
    }

    public func savePreferences(_ value: AppPreferences) async throws {
      try await preferences.save(value)
    }

    public func notificationPermissionState() async -> NotificationPermissionState {
      await notifications.permissionState()
    }

    public func requestNotificationPermission() async -> NotificationPermissionState {
      await notifications.requestPermission()
    }

    public func latestPeerState() async -> CompanionSyncState? {
      _ = await connectivity.activate()
      return await connectivity.latestReceivedState()
    }

    private func scheduleProactiveIfAllowed(
      for state: CompanionState,
      now: Date
    ) async -> NotificationPolicyDecision? {
      guard
        let saved = try? await preferences.load(),
        saved.proactiveMessagesEnabled,
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
              "outfit": state.pet.equippedOutfitID ?? "default",
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
