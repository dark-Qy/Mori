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

  @Test("Legacy request receives v1 revocation and both peers converge")
  func legacyConsentWireRevokesBothPeers() async throws {
    let initial = try snapshot(
      consent: enabledConsent(
        .remoteChat,
        revision: revision(7, "phone")
      )
    )
    let storage = InMemoryGlobalAuthorityStorage()
    let repository = try GlobalAuthorityRepository(
      storage: storage,
      initialSnapshot: initial
    )
    let runtime = GlobalAuthorityPeerSyncRuntime(repository: repository)
    let codec = GlobalAuthoritySyncWireCodec()
    let legacyPeer = LegacyV1OnlyAuthorityPeer(
      consent: enabledConsent(
        .remoteChat,
        revision: revision(999, "legacy-phone")
      )
    )
    let legacy = try await legacyPeer.consentPayload()

    let response = try await runtime.receive(
      channel: .consent,
      payload: legacy
    )
    _ = try await legacyPeer.exchange(
      channel: .consent,
      payload: response
    )
    let value = try await repository.current()
    let responseFrame = try codec.decodeConsent(response)
    let relaunched = try GlobalAuthorityRepository(
      storage: storage,
      initialSnapshot: initial
    )

    #expect(
      MoriConsentKind.allCases.allSatisfy {
        !value.consent[$0].enabled
      }
    )
    #expect(
      responseFrame.schemaVersion
        == GlobalConsentSyncFrame.legacySchemaVersion
    )
    #expect(responseFrame.deletionRoot == .bootstrap)
    #expect(responseFrame.consent == value.consent)
    #expect(
      responseFrame.consent.remoteChat.revision
        == revision(999, "legacy-phone")
    )
    #expect(
      await legacyPeer.currentConsent().allCapabilitiesDisabled
    )
    #expect(
      try await relaunched.current().consent.allCapabilitiesDisabled
    )
  }

  @Test("Unknown consent wire revokes instead of retaining local capability")
  func unknownConsentWireRevokesLocally() async throws {
    let initial = try snapshot(
      consent: enabledConsent(
        .memoryContext,
        revision: revision(7, "phone")
      )
    )
    let repository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: initial
    )
    let runtime = GlobalAuthorityPeerSyncRuntime(repository: repository)
    let codec = GlobalAuthoritySyncWireCodec()
    let valid = try codec.encode(
      GlobalConsentSyncFrame(
        deletionRoot: .bootstrap,
        consent: initial.consent
      )
    )
    var future = try #require(
      JSONSerialization.jsonObject(with: valid) as? [String: Any]
    )
    future["schemaVersion"] = 99
    let futureData = try JSONSerialization.data(
      withJSONObject: future,
      options: [.sortedKeys]
    )

    await #expect(
      throws: GlobalAuthoritySyncWireError.unsupportedSchema(99)
    ) {
      _ = try await runtime.receive(
        channel: .consent,
        payload: futureData
      )
    }
    #expect(
      try await repository.current().consent.memoryContext.enabled
        == false
    )
  }

  @Test("v2 initiator safely downgrades and converges after deletion")
  func v2InitiatorDowngradesAndConvergesAfterDeletion() async throws {
    let initial = try deletedSnapshot(
      consent: enabledConsent(
        .letterNotifications,
        revision: revision(11, "phone")
      )
    )
    let repository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: initial
    )
    let runtime = GlobalAuthorityPeerSyncRuntime(repository: repository)
    let legacyPeer = LegacyV1OnlyAuthorityPeer(
      consent: enabledConsent(
        .letterNotifications,
        revision: revision(999, "legacy-phone")
      )
    )

    let first = await runtime.handle(
      .foregroundActivation,
      using: legacyPeer
    )
    let valueAfterFirst = try await repository.current()
    let peerAfterFirst = await legacyPeer.currentConsent()
    let rejectionsAfterFirst = await legacyPeer.v2RejectionCount()
    let fallbacksAfterFirst = await legacyPeer.v1ExchangeCount()
    let second = await runtime.handle(
      .connectivityRestored,
      using: legacyPeer
    )
    let repeated = await runtime.handle(
      .backgroundRefresh,
      using: legacyPeer
    )
    let value = try await repository.current()

    #expect(first.consent == .retryRequired(.schemaIncompatible))
    #expect(valueAfterFirst.consent.allCapabilitiesDisabled)
    #expect(!peerAfterFirst.allCapabilitiesDisabled)
    #expect(rejectionsAfterFirst == 1)
    #expect(fallbacksAfterFirst == 1)
    #expect(!second.requiresRetry)
    #expect(!repeated.requiresRetry)
    #expect(value.deletionRoot == initial.deletionRoot)
    #expect(value.consent.allCapabilitiesDisabled)
    #expect(await legacyPeer.currentConsent().allCapabilitiesDisabled)
    #expect(await legacyPeer.v2RejectionCount() == 3)
    #expect(await legacyPeer.v1ExchangeCount() == 3)
  }

  @Test("Typed schema incompatibility also performs a safe v1 downgrade")
  func typedSchemaIncompatibilityDowngrades() async throws {
    let initial = try snapshot(
      consent: enabledConsent(
        .remoteChat,
        revision: revision(7, "phone")
      )
    )
    let repository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: initial
    )
    let runtime = GlobalAuthorityPeerSyncRuntime(repository: repository)
    let legacyPeer = LegacyV1OnlyAuthorityPeer(
      consent: initial.consent,
      rejectionStyle: .typedTransportError
    )

    let report = await runtime.handle(
      .connectivityRestored,
      using: legacyPeer
    )

    #expect(!report.requiresRetry)
    #expect(try await repository.current().consent.allCapabilitiesDisabled)
    #expect(await legacyPeer.currentConsent().allCapabilitiesDisabled)
    #expect(await legacyPeer.v2RejectionCount() == 1)
    #expect(await legacyPeer.v1ExchangeCount() == 1)
  }

  @Test("A post-commit concurrent grant cannot enter the v1 response")
  func concurrentGrantCannotEnterLegacyResponse() async throws {
    let initial = try snapshot(
      consent: enabledConsent(
        .memoryContext,
        revision: revision(7, "phone")
      )
    )
    let storage = AfterCommitPausingGlobalAuthorityStorage(
      pauseOnSaveNumber: 2
    )
    let repository = try GlobalAuthorityRepository(
      storage: storage,
      initialSnapshot: initial
    )
    let concurrentRepository = try GlobalAuthorityRepository(
      storage: storage,
      initialSnapshot: initial
    )
    let runtime = GlobalAuthorityPeerSyncRuntime(repository: repository)
    let codec = GlobalAuthoritySyncWireCodec()
    _ = try await concurrentRepository.current()
    let concurrentGrant = enabledConsent(
      .memoryContext,
      revision: revision(1_000, "phone")
    )
    let legacyRequest = try codec.encode(
      GlobalConsentSyncFrame(
        schemaVersion: GlobalConsentSyncFrame.legacySchemaVersion,
        deletionRoot: .bootstrap,
        consent: enabledConsent(
          .memoryContext,
          revision: revision(999, "legacy-phone")
        )
      )
    )
    let firstResponseTask = Task {
      try await runtime.receive(
        channel: .consent,
        payload: legacyRequest
      )
    }
    await storage.waitUntilSaveIsPaused()
    _ = try await concurrentRepository.merge(
      consent: concurrentGrant,
      deletionRoot: initial.deletionRoot
    )
    await storage.releaseSave()

    let firstResponse = try await firstResponseTask.value
    let firstFrame = try codec.decodeConsent(firstResponse)
    let stateAfterConcurrentGrant = try await repository.current()
    let secondResponse = try await runtime.receive(
      channel: .consent,
      payload: legacyRequest
    )
    let secondFrame = try codec.decodeConsent(secondResponse)
    let converged = try await repository.current()

    #expect(firstFrame.isLegacyV1)
    #expect(firstFrame.consent.allCapabilitiesDisabled)
    #expect(stateAfterConcurrentGrant.consent.memoryContext.enabled)
    #expect(secondFrame.consent.allCapabilitiesDisabled)
    #expect(converged.consent.allCapabilitiesDisabled)
    #expect(
      converged.consent.memoryContext.revision
        == revision(1_000, "phone")
    )
  }

  @Test("Offline consent exchange retries without revoking authority")
  func offlineDoesNotMasqueradeAsSchemaIncompatibility() async throws {
    let initial = try snapshot(
      consent: enabledConsent(
        .remoteChat,
        revision: revision(7, "phone")
      )
    )
    let repository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: initial
    )
    let runtime = GlobalAuthorityPeerSyncRuntime(repository: repository)
    let offline = InMemoryGlobalAuthorityPeerTransport(
      isAvailable: false
    ) { _, _ in
      Issue.record("Offline transport must not call the peer")
      return Data()
    }

    let report = await runtime.handle(
      .connectivityRestored,
      using: offline
    )

    #expect(report.preferences == .retryRequired(.offline))
    #expect(report.consent == .retryRequired(.offline))
    #expect(try await repository.current().consent.remoteChat.enabled)
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
      deletionRoot: .bootstrap,
      consent: enabledConsent(
        .letterNotifications,
        revision: revision(3, "phone")
      )
    )
    let codec = GlobalAuthoritySyncWireCodec()
    let canonical = try codec.encode(frame)
    #expect(try codec.decodeConsent(canonical) == frame)

    var legacy = try #require(
      JSONSerialization.jsonObject(with: canonical) as? [String: Any]
    )
    legacy["schemaVersion"] = 1
    legacy.removeValue(forKey: "deletionRoot")
    let legacyData = try JSONSerialization.data(
      withJSONObject: legacy,
      options: [.sortedKeys]
    )
    let legacyFrame = try codec.decodeConsent(legacyData)
    #expect(legacyFrame.isLegacyV1)
    #expect(legacyFrame.deletionRoot == .bootstrap)
    #expect(legacyFrame.consent == frame.consent)
    #expect(throws: GlobalAuthoritySyncWireError.invalidDeletionRoot) {
      try codec.encode(
        GlobalConsentSyncFrame(
          deletionRoot: .deletion(.bootstrap),
          consent: frame.consent
        )
      )
    }

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

  private func deletedSnapshot(
    consent: GlobalConsentState
  ) throws -> GlobalAuthoritySnapshot {
    let deletionRevision = revision(10, "phone")
    let profile = RuntimeProfile(
      id: ProfileID("real"),
      epoch: ProfileEpoch(deletionRevision),
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("delete-before-v1-peer"),
        revision: deletionRevision
      ),
      source: .real
    )
    return GlobalAuthoritySnapshot(
      preferences: GlobalSyncedPreferences(
        profileSelection: try .real(
          profile: profile,
          selectionRevision: deletionRevision
        ),
        companionSensing: RevisionedPreference(
          value: CompanionSensingPreference(
            enabled: false,
            epoch: SensingEpoch(deletionRevision)
          ),
          revision: deletionRevision
        ),
        reminderMode: RevisionedPreference(
          value: .wristRaise,
          revision: deletionRevision
        ),
        quietHours: RevisionedPreference(
          value: CompanionQuietHours(
            startMinute: 22 * 60,
            endMinute: 7 * 60
          ),
          revision: deletionRevision
        )
      ),
      consent: consent
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
      deletionEpoch: .bootstrap,
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

private actor LegacyV1OnlyAuthorityPeer: GlobalAuthorityPeerTransport {
  enum RejectionStyle: Sendable {
    case legacyWireError
    case typedTransportError
  }

  private let codec = GlobalAuthoritySyncWireCodec()
  private let rejectionStyle: RejectionStyle
  private var consent: GlobalConsentState
  private var rejectedV2Count = 0
  private var acceptedV1Count = 0

  init(
    consent: GlobalConsentState,
    rejectionStyle: RejectionStyle = .legacyWireError
  ) {
    self.consent = consent
    self.rejectionStyle = rejectionStyle
  }

  func exchange(
    channel: GlobalAuthoritySyncChannel,
    payload: Data
  ) throws -> Data {
    guard channel == .consent else { return payload }
    let schemaVersion = try schemaVersion(in: payload)
    guard schemaVersion == GlobalConsentSyncFrame.legacySchemaVersion else {
      rejectedV2Count += 1
      switch rejectionStyle {
      case .legacyWireError:
        throw GlobalAuthoritySyncWireError.unsupportedSchema(
          schemaVersion
        )
      case .typedTransportError:
        throw GlobalAuthorityPeerTransportError.schemaIncompatible(
          channel: .consent,
          receivedSchemaVersion: schemaVersion,
          maximumSupportedSchemaVersion:
            GlobalConsentSyncFrame.legacySchemaVersion
        )
      }
    }

    let frame = try codec.decodeConsent(payload)
    guard frame.isLegacyV1 else {
      throw GlobalAuthoritySyncWireError.unsupportedSchema(
        frame.schemaVersion
      )
    }
    acceptedV1Count += 1
    switch GlobalConsentMerger.merge(
      current: consent,
      incoming: frame.consent
    ) {
    case .applied(let merged), .duplicate(let merged):
      consent = merged
    case .rejected(let reason):
      throw GlobalAuthorityPeerSyncError.rejectedConsent(reason)
    }
    return try consentPayload()
  }

  func consentPayload() throws -> Data {
    try codec.encode(
      GlobalConsentSyncFrame(
        schemaVersion: GlobalConsentSyncFrame.legacySchemaVersion,
        deletionRoot: .bootstrap,
        consent: consent
      )
    )
  }

  func currentConsent() -> GlobalConsentState {
    consent
  }

  func v2RejectionCount() -> Int {
    rejectedV2Count
  }

  func v1ExchangeCount() -> Int {
    acceptedV1Count
  }

  private func schemaVersion(in payload: Data) throws -> UInt16 {
    let object: [String: Any]
    do {
      guard
        let decoded =
          try JSONSerialization.jsonObject(with: payload)
          as? [String: Any]
      else {
        throw GlobalAuthoritySyncWireError.malformed
      }
      object = decoded
    } catch {
      throw GlobalAuthoritySyncWireError.malformed
    }
    guard
      let number = object["schemaVersion"] as? NSNumber,
      let version = UInt16(exactly: number.uint64Value)
    else {
      throw GlobalAuthoritySyncWireError.malformed
    }
    return version
  }
}

private actor AfterCommitPausingGlobalAuthorityStorage:
  GlobalAuthorityStorage
{
  private var data: Data?
  private let pauseOnSaveNumber: Int
  private var saveCount = 0
  private var saveIsPaused = false
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(pauseOnSaveNumber: Int) {
    self.pauseOnSaveNumber = pauseOnSaveNumber
  }

  func load() -> GlobalAuthorityStorageSnapshot {
    GlobalAuthorityStorageSnapshot(
      data: data,
      revision: .current(for: data)
    )
  }

  func save(
    _ data: Data,
    replacing expectedRevision: GlobalAuthorityStorageRevision
  ) async throws -> GlobalAuthorityStorageRevision {
    guard
      GlobalAuthorityStorageRevision.current(for: self.data)
        == expectedRevision
    else {
      throw GlobalAuthorityRepositoryError.staleStorageRevision
    }
    self.data = data
    saveCount += 1
    let committedRevision = GlobalAuthorityStorageRevision.current(
      for: data
    )
    if saveCount == pauseOnSaveNumber {
      saveIsPaused = true
      let waiters = pauseWaiters
      pauseWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        releaseWaiters.append(continuation)
      }
      saveIsPaused = false
    }
    return committedRevision
  }

  func waitUntilSaveIsPaused() async {
    guard !saveIsPaused else { return }
    await withCheckedContinuation { continuation in
      pauseWaiters.append(continuation)
    }
  }

  func releaseSave() {
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

extension GlobalConsentState {
  fileprivate var allCapabilitiesDisabled: Bool {
    MoriConsentKind.allCases.allSatisfy { !self[$0].enabled }
  }
}
