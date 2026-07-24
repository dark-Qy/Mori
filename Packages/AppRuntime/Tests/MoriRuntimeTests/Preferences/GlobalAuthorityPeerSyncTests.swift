import Foundation
import MoriDomain
import Testing

@testable import MoriRuntime

@Suite("Global authority automatic peer sync")
struct GlobalAuthorityPeerSyncTests {
  @Test("Lifecycle exchange converges preference and consent channels")
  func lifecycleExchangeConvergesBothChannels() async throws {
    let phoneSnapshot = try snapshot(
      reminderRevision: revision(3, "phone"),
      reminderMode: .gentleHaptic,
      consent: enabledConsent(
        .dailyMemoryNotifications,
        revision: revision(3, "phone")
      )
    )
    let watchSnapshot = try snapshot(
      quietRevision: revision(2, "watch"),
      quietHours: CompanionQuietHours(
        startMinute: 23 * 60,
        endMinute: 8 * 60
      ),
      consent: revokedConsent(
        .dailyMemoryNotifications,
        revision: revision(4, "watch")
      )
    )
    let phoneRepository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: phoneSnapshot
    )
    let watchRepository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: watchSnapshot
    )
    let phone = GlobalAuthorityPeerSyncRuntime(repository: phoneRepository)
    let watch = GlobalAuthorityPeerSyncRuntime(repository: watchRepository)
    let transport = InMemoryGlobalAuthorityPeerTransport { channel, payload in
      try await watch.receive(channel: channel, payload: payload)
    }

    let report = await phone.handle(
      .foregroundActivation,
      using: transport
    )

    #expect(!report.requiresRetry)
    let exchangeLog = await transport.exchangeLog()
    #expect(exchangeLog.count == 2)
    #expect(Set(exchangeLog) == Set(GlobalAuthoritySyncChannel.allCases))
    let phoneValue = try await phoneRepository.current()
    let watchValue = try await watchRepository.current()
    #expect(phoneValue == watchValue)
    #expect(phoneValue.preferences.reminderMode.value == .gentleHaptic)
    #expect(
      phoneValue.preferences.quietHours.value
        == CompanionQuietHours(
          startMinute: 23 * 60,
          endMinute: 8 * 60
        )
    )
    #expect(!phoneValue.consent.dailyMemoryNotifications.enabled)
    #expect(
      phoneValue.consent.dailyMemoryNotifications.revision
        == revision(4, "watch")
    )
  }

  @Test("One channel failure does not starve the other and retries automatically")
  func channelFailureIsIndependentAndRetryable() async throws {
    let phoneSnapshot = try snapshot(
      reminderRevision: revision(4, "phone"),
      reminderMode: .gentleHaptic,
      consent: enabledConsent(
        .letterNotifications,
        revision: revision(5, "phone")
      )
    )
    let watchSnapshot = try snapshot()
    let phoneRepository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: phoneSnapshot
    )
    let watchRepository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: watchSnapshot
    )
    let phone = GlobalAuthorityPeerSyncRuntime(repository: phoneRepository)
    let watch = GlobalAuthorityPeerSyncRuntime(repository: watchRepository)
    let transport = InMemoryGlobalAuthorityPeerTransport { channel, payload in
      try await watch.receive(channel: channel, payload: payload)
    }
    await transport.failNext(.preferences)

    let first = await phone.handle(.backgroundRefresh, using: transport)

    #expect(first.preferences == .retryRequired(.transportOrPersistence))
    #expect(first.consent == .synchronized(localStateChanged: false))
    var watchValue = try await watchRepository.current()
    #expect(watchValue.preferences.reminderMode.value == .wristRaise)
    #expect(watchValue.consent.letterNotifications.enabled)

    let second = await phone.handle(.connectivityRestored, using: transport)

    #expect(!second.requiresRetry)
    watchValue = try await watchRepository.current()
    #expect(watchValue.preferences.reminderMode.value == .gentleHaptic)
    let exchangeLog = await transport.exchangeLog()
    #expect(exchangeLog.filter { $0 == .preferences }.count == 2)
    #expect(exchangeLog.filter { $0 == .consent }.count == 2)
  }

  @Test("Peer conflict cannot block a newer sensing revocation")
  func peerConflictStillConvergesSensingRevocation() async throws {
    let phoneRepository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: try snapshot(
        sensingRevision: revision(5, "phone"),
        sensingEnabled: false,
        reminderRevision: revision(3, "shared"),
        reminderMode: .wristRaise
      )
    )
    let watchRepository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: try snapshot(
        sensingRevision: revision(1, "phone"),
        reminderRevision: revision(3, "shared"),
        reminderMode: .gentleHaptic
      )
    )
    let phone = GlobalAuthorityPeerSyncRuntime(repository: phoneRepository)
    let watch = GlobalAuthorityPeerSyncRuntime(repository: watchRepository)
    let transport = InMemoryGlobalAuthorityPeerTransport { channel, payload in
      try await watch.receive(channel: channel, payload: payload)
    }

    let report = await phone.handle(.connectivityRestored, using: transport)

    #expect(!report.requiresRetry)
    let phoneValue = try await phoneRepository.current()
    let watchValue = try await watchRepository.current()
    #expect(phoneValue == watchValue)
    #expect(!phoneValue.preferences.companionSensing.value.enabled)
    #expect(
      phoneValue.preferences.companionSensing.revision
        == revision(5, "phone")
    )
  }

  @Test("A hanging preference channel cannot delay consent revocation")
  func hangingPreferencesCannotStarveConsent() async throws {
    let phoneRepository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: try snapshot(
        consent: revokedConsent(
          .remoteChat,
          revision: revision(8, "phone")
        )
      )
    )
    let watchRepository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: try snapshot(
        consent: enabledConsent(
          .remoteChat,
          revision: revision(7, "phone")
        )
      )
    )
    let phone = GlobalAuthorityPeerSyncRuntime(
      repository: phoneRepository,
      channelTimeout: .seconds(1)
    )
    let watch = GlobalAuthorityPeerSyncRuntime(repository: watchRepository)
    let transport = HangingPreferenceTransport { channel, payload in
      try await watch.receive(channel: channel, payload: payload)
    }

    let report = await phone.handle(
      .connectivityRestored,
      using: transport
    )

    #expect(report.preferences == .retryRequired(.timedOut))
    #expect(!report.consent.requiresRetry)
    #expect(!(try await watchRepository.current().consent.remoteChat.enabled))
    #expect(await transport.completedConsentExchangeCount() == 1)
  }

  @Test("Durable latest state survives offline failure and process relaunch")
  func offlineRelaunchRetriesDurableLatestState() async throws {
    let baseline = try snapshot()
    let changed = try preferences(
      reminderRevision: revision(7, "phone"),
      reminderMode: .gentleHaptic
    )
    let phoneStorage = InMemoryGlobalAuthorityStorage()
    let firstRepository = try GlobalAuthorityRepository(
      storage: phoneStorage,
      initialSnapshot: baseline
    )
    _ = try await firstRepository.merge(preferences: changed)
    let firstRuntime = GlobalAuthorityPeerSyncRuntime(
      repository: firstRepository
    )
    let offline = InMemoryGlobalAuthorityPeerTransport(
      isAvailable: false
    ) { _, _ in
      Issue.record("Offline transport must not call the peer")
      return Data()
    }

    let failed = await firstRuntime.handle(.backgroundRefresh, using: offline)
    #expect(failed.preferences.requiresRetry)
    #expect(failed.consent.requiresRetry)

    let watchRepository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: baseline
    )
    let watch = GlobalAuthorityPeerSyncRuntime(repository: watchRepository)
    let relaunchedRepository = try GlobalAuthorityRepository(
      storage: phoneStorage,
      initialSnapshot: baseline
    )
    let relaunched = GlobalAuthorityPeerSyncRuntime(
      repository: relaunchedRepository
    )
    let online = InMemoryGlobalAuthorityPeerTransport { channel, payload in
      try await watch.receive(channel: channel, payload: payload)
    }

    let retried = await relaunched.handle(
      .connectivityRestored,
      using: online
    )

    #expect(!retried.requiresRetry)
    #expect(
      try await watchRepository.current().preferences.reminderMode.value
        == .gentleHaptic
    )
  }

  @Test("Lost response retries after relaunch when peer already persisted")
  func lostResponseAfterPeerPersistenceRetries() async throws {
    let baseline = try snapshot()
    let changed = try preferences(
      reminderRevision: revision(9, "phone"),
      reminderMode: .gentleHaptic
    )
    let phoneStorage = InMemoryGlobalAuthorityStorage()
    let phoneRepository = try GlobalAuthorityRepository(
      storage: phoneStorage,
      initialSnapshot: baseline
    )
    _ = try await phoneRepository.merge(preferences: changed)
    let watchStorage = InMemoryGlobalAuthorityStorage()
    let watchRepository = try GlobalAuthorityRepository(
      storage: watchStorage,
      initialSnapshot: baseline
    )
    let phone = GlobalAuthorityPeerSyncRuntime(repository: phoneRepository)
    let watch = GlobalAuthorityPeerSyncRuntime(repository: watchRepository)
    let dropping = DroppingResponseTransport(
      dropOnce: .preferences
    ) { channel, payload in
      try await watch.receive(channel: channel, payload: payload)
    }

    let first = await phone.handle(.foregroundActivation, using: dropping)

    #expect(first.preferences.requiresRetry)
    #expect(
      try await watchRepository.current().preferences.reminderMode.value
        == .gentleHaptic
    )

    let relaunchedPhoneRepository = try GlobalAuthorityRepository(
      storage: phoneStorage,
      initialSnapshot: baseline
    )
    let relaunchedWatchRepository = try GlobalAuthorityRepository(
      storage: watchStorage,
      initialSnapshot: baseline
    )
    let relaunchedPhone = GlobalAuthorityPeerSyncRuntime(
      repository: relaunchedPhoneRepository
    )
    let relaunchedWatch = GlobalAuthorityPeerSyncRuntime(
      repository: relaunchedWatchRepository
    )
    let stable = InMemoryGlobalAuthorityPeerTransport { channel, payload in
      try await relaunchedWatch.receive(channel: channel, payload: payload)
    }

    let retried = await relaunchedPhone.handle(
      .connectivityRestored,
      using: stable
    )

    #expect(!retried.requiresRetry)
    #expect(
      try await relaunchedPhoneRepository.current()
        == relaunchedWatchRepository.current()
    )
  }

  @Test("Duplicate delayed and reordered frames converge")
  func duplicateDelayedReorderedFramesConverge() async throws {
    let baseline = try snapshot()
    let repository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: baseline
    )
    let runtime = GlobalAuthorityPeerSyncRuntime(repository: repository)
    let codec = GlobalAuthoritySyncWireCodec()
    let older = try preferences(
      reminderRevision: revision(2, "phone"),
      reminderMode: .gentleHaptic
    )
    let newer = try preferences(
      reminderRevision: revision(4, "watch"),
      reminderMode: .wristRaise,
      quietRevision: revision(3, "watch"),
      quietHours: CompanionQuietHours(
        startMinute: 23 * 60,
        endMinute: 9 * 60
      )
    )
    let olderBytes = try codec.encode(
      GlobalPreferenceSyncFrame(preferences: older)
    )
    let newerBytes = try codec.encode(
      GlobalPreferenceSyncFrame(preferences: newer)
    )

    _ = try await runtime.receive(channel: .preferences, payload: newerBytes)
    _ = try await runtime.receive(channel: .preferences, payload: olderBytes)
    _ = try await runtime.receive(channel: .preferences, payload: newerBytes)

    let value = try await repository.current().preferences
    #expect(value.reminderMode.revision == revision(4, "watch"))
    #expect(
      value.quietHours.value
        == CompanionQuietHours(
          startMinute: 23 * 60,
          endMinute: 9 * 60
        )
    )
  }

  @Test("Concurrent peer activations converge without duplicate authority")
  func concurrentBidirectionalSyncConverges() async throws {
    let phoneRepository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: try snapshot(
        reminderRevision: revision(5, "phone"),
        reminderMode: .gentleHaptic
      )
    )
    let watchRepository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: try snapshot(
        quietRevision: revision(6, "watch"),
        quietHours: CompanionQuietHours(
          startMinute: 21 * 60,
          endMinute: 6 * 60
        )
      )
    )
    let phone = GlobalAuthorityPeerSyncRuntime(repository: phoneRepository)
    let watch = GlobalAuthorityPeerSyncRuntime(repository: watchRepository)
    let phoneToWatch = InMemoryGlobalAuthorityPeerTransport {
      channel,
      payload in
      try await watch.receive(channel: channel, payload: payload)
    }
    let watchToPhone = InMemoryGlobalAuthorityPeerTransport {
      channel,
      payload in
      try await phone.receive(channel: channel, payload: payload)
    }

    async let phoneReport = phone.handle(
      .foregroundActivation,
      using: phoneToWatch
    )
    async let watchReport = watch.handle(
      .foregroundActivation,
      using: watchToPhone
    )
    let reports = await (phoneReport, watchReport)

    #expect(!reports.0.requiresRetry)
    #expect(!reports.1.requiresRetry)
    let phoneValue = try await phoneRepository.current()
    let watchValue = try await watchRepository.current()
    #expect(phoneValue == watchValue)
    #expect(phoneValue.preferences.reminderMode.value == .gentleHaptic)
    #expect(
      phoneValue.preferences.quietHours.value
        == CompanionQuietHours(
          startMinute: 21 * 60,
          endMinute: 6 * 60
        )
    )
  }

  @Test("Wire is canonical closed versioned bounded and excludes DLS")
  func wireFailsClosed() throws {
    let frame = GlobalPreferenceSyncFrame(
      preferences: try preferences()
    )
    let codec = GlobalAuthoritySyncWireCodec()
    let canonical = try codec.encode(frame)
    #expect(try codec.decodePreferences(canonical) == frame)

    var injected = try #require(
      JSONSerialization.jsonObject(with: canonical) as? [String: Any]
    )
    injected["deviceLocalState"] = ["notificationAuthorization": "authorized"]
    let injectedData = try JSONSerialization.data(
      withJSONObject: injected,
      options: [.sortedKeys]
    )
    #expect(
      throws: GlobalAuthoritySyncWireError.undeclaredField(
        "$.deviceLocalState"
      )
    ) {
      try codec.decodePreferences(injectedData)
    }

    let nonCanonical = Data(" \n".utf8) + canonical
    #expect(throws: GlobalAuthoritySyncWireError.nonCanonical) {
      try codec.decodePreferences(nonCanonical)
    }

    var future = try #require(
      JSONSerialization.jsonObject(with: canonical) as? [String: Any]
    )
    future["schemaVersion"] = 99
    let futureData = try JSONSerialization.data(
      withJSONObject: future,
      options: [.sortedKeys]
    )
    #expect(throws: GlobalAuthoritySyncWireError.unsupportedSchema(99)) {
      try codec.decodePreferences(futureData)
    }

    #expect(
      throws: GlobalAuthoritySyncWireError.oversized(
        actualBytes: canonical.count,
        maximumBytes: canonical.count - 1
      )
    ) {
      try GlobalAuthoritySyncWireCodec(
        maximumBytes: canonical.count - 1
      ).decodePreferences(canonical)
    }
  }

  @Test("Consent wire has symmetric closed canonical version and size gates")
  func consentWireFailsClosed() throws {
    let frame = GlobalConsentSyncFrame(
      consent: enabledConsent(
        .letterNotifications,
        revision: revision(3, "phone")
      )
    )
    let codec = GlobalAuthoritySyncWireCodec()
    let canonical = try codec.encode(frame)
    #expect(try codec.decodeConsent(canonical) == frame)

    var injected = try #require(
      JSONSerialization.jsonObject(with: canonical) as? [String: Any]
    )
    injected["deviceLocalNotificationAuthorization"] = "authorized"
    let injectedData = try JSONSerialization.data(
      withJSONObject: injected,
      options: [.sortedKeys]
    )
    #expect(
      throws: GlobalAuthoritySyncWireError.undeclaredField(
        "$.deviceLocalNotificationAuthorization"
      )
    ) {
      try codec.decodeConsent(injectedData)
    }

    let nonCanonical = Data("\n".utf8) + canonical
    #expect(throws: GlobalAuthoritySyncWireError.nonCanonical) {
      try codec.decodeConsent(nonCanonical)
    }

    var future = try #require(
      JSONSerialization.jsonObject(with: canonical) as? [String: Any]
    )
    future["schemaVersion"] = 99
    let futureData = try JSONSerialization.data(
      withJSONObject: future,
      options: [.sortedKeys]
    )
    #expect(throws: GlobalAuthoritySyncWireError.unsupportedSchema(99)) {
      try codec.decodeConsent(futureData)
    }

    #expect(
      throws: GlobalAuthoritySyncWireError.oversized(
        actualBytes: canonical.count,
        maximumBytes: canonical.count - 1
      )
    ) {
      try GlobalAuthoritySyncWireCodec(
        maximumBytes: canonical.count - 1
      ).decodeConsent(canonical)
    }
  }

  private func snapshot(
    sensingRevision: LamportRevision? = nil,
    sensingEnabled: Bool = true,
    reminderRevision: LamportRevision? = nil,
    reminderMode: CompanionReminderMode = .wristRaise,
    quietRevision: LamportRevision? = nil,
    quietHours: CompanionQuietHours = CompanionQuietHours(
      startMinute: 22 * 60,
      endMinute: 7 * 60
    ),
    consent: GlobalConsentState? = nil
  ) throws -> GlobalAuthoritySnapshot {
    GlobalAuthoritySnapshot(
      preferences: try preferences(
        sensingRevision: sensingRevision,
        sensingEnabled: sensingEnabled,
        reminderRevision: reminderRevision,
        reminderMode: reminderMode,
        quietRevision: quietRevision,
        quietHours: quietHours
      ),
      consent: consent
        ?? .disabled(
          revision: revision(1, "phone"),
          authorDevice: .phone
        )
    )
  }

  private func preferences(
    sensingRevision: LamportRevision? = nil,
    sensingEnabled: Bool = true,
    reminderRevision: LamportRevision? = nil,
    reminderMode: CompanionReminderMode = .wristRaise,
    quietRevision: LamportRevision? = nil,
    quietHours: CompanionQuietHours = CompanionQuietHours(
      startMinute: 22 * 60,
      endMinute: 7 * 60
    )
  ) throws -> GlobalSyncedPreferences {
    let base = revision(1, "phone")
    let profile = RuntimeProfile(
      id: ProfileID("real"),
      epoch: ProfileEpoch(base),
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("baseline"),
        revision: base
      ),
      source: .real
    )
    return GlobalSyncedPreferences(
      profileSelection: try .real(
        profile: profile,
        selectionRevision: base
      ),
      companionSensing: RevisionedPreference(
        value: CompanionSensingPreference(
          enabled: sensingEnabled,
          epoch: SensingEpoch(sensingRevision ?? base)
        ),
        revision: sensingRevision ?? base
      ),
      reminderMode: RevisionedPreference(
        value: reminderMode,
        revision: reminderRevision ?? base
      ),
      quietHours: RevisionedPreference(
        value: quietHours,
        revision: quietRevision ?? base
      )
    )
  }

  private func enabledConsent(
    _ kind: MoriConsentKind,
    revision: LamportRevision
  ) -> GlobalConsentState {
    GlobalConsentState.disabled(
      revision: self.revision(1, "phone"),
      authorDevice: .phone
    ).replacing(
      kind,
      with: MoriConsentRecord(
        enabled: true,
        disclosureVersion: kind.requiredDisclosureVersion,
        revision: revision,
        authorDevice: .phone
      )
    )
  }

  private func revokedConsent(
    _ kind: MoriConsentKind,
    revision: LamportRevision
  ) -> GlobalConsentState {
    GlobalConsentState.disabled(
      revision: self.revision(1, "phone"),
      authorDevice: .phone
    ).replacing(
      kind,
      with: MoriConsentRecord(
        enabled: false,
        disclosureVersion: 0,
        revision: revision,
        authorDevice: .watch
      )
    )
  }

  private func revision(_ counter: UInt64, _ device: String) -> LamportRevision {
    LamportRevision(counter: counter, originDeviceID: device)
  }
}

private actor HangingPreferenceTransport: GlobalAuthorityPeerTransport {
  typealias Handler =
    @Sendable (GlobalAuthoritySyncChannel, Data) async throws -> Data

  private let handler: Handler
  private var consentExchangeCount = 0

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func exchange(
    channel: GlobalAuthoritySyncChannel,
    payload: Data
  ) async throws -> Data {
    if channel == .preferences {
      try await Task.sleep(for: .seconds(60))
    } else {
      consentExchangeCount += 1
    }
    return try await handler(channel, payload)
  }

  func completedConsentExchangeCount() -> Int {
    consentExchangeCount
  }
}

private actor DroppingResponseTransport: GlobalAuthorityPeerTransport {
  typealias Handler =
    @Sendable (GlobalAuthoritySyncChannel, Data) async throws -> Data

  private let handler: Handler
  private var channelToDrop: GlobalAuthoritySyncChannel?

  init(
    dropOnce channel: GlobalAuthoritySyncChannel,
    handler: @escaping Handler
  ) {
    channelToDrop = channel
    self.handler = handler
  }

  func exchange(
    channel: GlobalAuthoritySyncChannel,
    payload: Data
  ) async throws -> Data {
    let response = try await handler(channel, payload)
    if channelToDrop == channel {
      channelToDrop = nil
      throw GlobalAuthorityPeerTransportError.injectedFailure(channel)
    }
    return response
  }
}
