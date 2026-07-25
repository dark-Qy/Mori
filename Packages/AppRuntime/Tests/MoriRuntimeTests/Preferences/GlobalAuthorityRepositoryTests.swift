import Foundation
import MoriDomain
import MoriPersistence
import Testing

@testable import MoriRuntime

@Suite("Durable global authority")
struct GlobalAuthorityRepositoryTests {
  @Test("Preference and consent merges survive repository recreation")
  func durableRoundTrip() async throws {
    let initial = try makeSnapshot()
    let storage = InMemoryGlobalAuthorityStorage()
    let first = try GlobalAuthorityRepository(
      storage: storage,
      initialSnapshot: initial
    )
    let incomingPreferences = try makePreferences(
      reminderRevision: revision(2, "watch"),
      reminderMode: .gentleHaptic
    )
    _ = try await first.merge(preferences: incomingPreferences)
    let incomingConsent = initial.consent.replacing(
      .dailyMemoryNotifications,
      with: MoriConsentRecord(
        enabled: true,
        disclosureVersion: 1,
        revision: revision(2, "phone"),
        authorDevice: .phone
      )
    )
    _ = try await first.merge(
      consent: incomingConsent,
      deletionRoot: initial.deletionRoot
    )

    let reopened = try GlobalAuthorityRepository(
      storage: storage,
      initialSnapshot: initial
    )
    let value = try await reopened.current()

    #expect(value.preferences.reminderMode.value == .gentleHaptic)
    #expect(value.consent.dailyMemoryNotifications.enabled)
  }

  @Test("Consent from an older deletion root cannot revive after deletion")
  func staleRootConsentCannotReviveAfterDeletion() async throws {
    let initial = try makeSnapshot()
    let repository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: initial
    )
    let deletion = try makeDeletionSnapshot(
      revision: revision(10, "phone"),
      requestID: "delete-consent-fence"
    )
    try await repository.replaceForDeletion(with: deletion)
    let staleEnabled = initial.consent.replacing(
      .remoteChat,
      with: MoriConsentRecord(
        enabled: true,
        disclosureVersion: MoriConsentKind.remoteChat.requiredDisclosureVersion,
        revision: revision(999, "offline-watch"),
        authorDevice: .phone
      )
    )

    let result = try await repository.merge(
      consent: staleEnabled,
      deletionRoot: .bootstrap
    )
    let value = try await repository.current()

    #expect(result == .duplicate(deletion.consent))
    #expect(value.deletionRoot == deletion.deletionRoot)
    #expect(!value.consent.remoteChat.enabled)
  }

  @Test("A preference deletion fence atomically revokes old-root consent")
  func preferenceFenceRevokesConsentAtomically() async throws {
    let base = try makeSnapshot()
    let enabled = base.consent.replacing(
      .remoteChat,
      with: MoriConsentRecord(
        enabled: true,
        disclosureVersion: MoriConsentKind.remoteChat.requiredDisclosureVersion,
        revision: revision(999, "offline-phone"),
        authorDevice: .phone
      )
    )
    let initial = GlobalAuthoritySnapshot(
      preferences: base.preferences,
      consent: enabled
    )
    let repository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: initial
    )
    let deletion = try makeDeletionSnapshot(
      revision: revision(10, "phone"),
      requestID: "delete-via-preference-channel"
    )

    _ = try await repository.merge(preferences: deletion.preferences)
    let value = try await repository.current()

    #expect(value.deletionRoot == deletion.deletionRoot)
    #expect(value.consent == deletion.consent)
    #expect(!value.consent.remoteChat.enabled)
  }

  @Test("Future-root consent waits for its matching preference fence")
  func futureRootConsentRequiresPreferenceFenceFirst() async throws {
    let initial = try makeSnapshot()
    let repository = try GlobalAuthorityRepository(
      storage: InMemoryGlobalAuthorityStorage(),
      initialSnapshot: initial
    )
    let deletion = try makeDeletionSnapshot(
      revision: revision(10, "phone"),
      requestID: "delete-before-consent"
    )
    let futureConsent = deletion.consent.replacing(
      .letterNotifications,
      with: MoriConsentRecord(
        enabled: true,
        disclosureVersion:
          MoriConsentKind.letterNotifications.requiredDisclosureVersion,
        revision: revision(11, "phone"),
        authorDevice: .phone
      )
    )

    await #expect(
      throws: GlobalAuthorityRepositoryError.deletionRootMismatch(
        expected: .bootstrap,
        received: deletion.deletionRoot
      )
    ) {
      _ = try await repository.merge(
        consent: futureConsent,
        deletionRoot: deletion.deletionRoot
      )
    }
    #expect(try await repository.current() == initial)

    try await repository.replaceForDeletion(with: deletion)
    let result = try await repository.merge(
      consent: futureConsent,
      deletionRoot: deletion.deletionRoot
    )

    #expect(result == .applied(futureConsent))
    #expect(try await repository.current().consent == futureConsent)
  }

  @Test("Concurrent suspended writes retain both independent changes")
  func concurrentWritesAreSerialized() async throws {
    let initial = try makeSnapshot()
    let storage = PausingGlobalAuthorityStorage()
    let repository = try GlobalAuthorityRepository(
      storage: storage,
      initialSnapshot: initial
    )
    _ = try await repository.current()

    let reminderChange = try makePreferences(
      reminderRevision: revision(2, "phone"),
      reminderMode: .gentleHaptic
    )
    let quietChange = try makePreferences(
      quietRevision: revision(3, "watch"),
      quietHours: CompanionQuietHours(startMinute: 23 * 60, endMinute: 8 * 60)
    )
    await storage.pauseNextSave()
    let first = Task {
      try await repository.merge(preferences: reminderChange)
    }
    await storage.waitUntilSaveIsPaused()
    let second = Task {
      try await repository.merge(preferences: quietChange)
    }
    await storage.releaseSave()
    _ = try await first.value
    _ = try await second.value

    let value = try await repository.current()
    #expect(value.preferences.reminderMode.value == .gentleHaptic)
    #expect(
      value.preferences.quietHours.value
        == CompanionQuietHours(startMinute: 23 * 60, endMinute: 8 * 60)
    )
  }

  @Test("A paused stale repository cannot overwrite a newer deletion fence")
  func staleConcurrentWriteCannotOverwriteDeletionFence() async throws {
    let initial = try makeSnapshot()
    let storage = PausingGlobalAuthorityStorage()
    let stale = try GlobalAuthorityRepository(
      storage: storage,
      initialSnapshot: initial
    )
    let deleting = try GlobalAuthorityRepository(
      storage: storage,
      initialSnapshot: initial
    )
    _ = try await stale.current()
    _ = try await deleting.current()

    let stalePreference = try makePreferences(
      reminderRevision: revision(50, "watch"),
      reminderMode: .gentleHaptic
    )
    let deletionFence = try makeDeletionSnapshot(
      revision: revision(10, "phone"),
      requestID: "delete-concurrent"
    )
    await storage.pauseNextSave()
    let staleWrite = Task {
      try await stale.merge(preferences: stalePreference)
    }
    await storage.waitUntilSaveIsPaused()

    try await deleting.replaceForDeletion(with: deletionFence)
    await storage.releaseSave()
    await #expect(
      throws: GlobalAuthorityRepositoryError.staleStorageRevision
    ) {
      _ = try await staleWrite.value
    }

    let refreshed = try await stale.current()
    #expect(refreshed == deletionFence)
    #expect(!refreshed.preferences.companionSensing.value.enabled)
    #expect(
      refreshed.preferences.profileSelection.profile.deletionEpoch.requestID
        == DeletionRequestID("delete-concurrent")
    )
  }

  @Test("File CAS rejects a stale instance and preserves deletion across restart")
  func fileCASPreservesDeletionFenceAcrossRestart() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("authority.json")
    let initial = try makeSnapshot()
    let codec = GlobalAuthorityCodec()
    let firstStorage = FileGlobalAuthorityStorage(fileURL: fileURL)
    let staleStorage = FileGlobalAuthorityStorage(fileURL: fileURL)
    let firstRevision = try await firstStorage.load().revision
    let staleRevision = try await staleStorage.load().revision
    #expect(firstRevision == .absent)
    #expect(staleRevision == .absent)

    let deletionFence = try makeDeletionSnapshot(
      revision: revision(10, "phone"),
      requestID: "delete-file"
    )
    _ = try await firstStorage.save(
      codec.encode(deletionFence),
      replacing: firstRevision
    )
    let staleValue = try makeSnapshot(
      preferences: makePreferences(
        reminderRevision: revision(100, "watch"),
        reminderMode: .gentleHaptic
      )
    )
    await #expect(
      throws: GlobalAuthorityRepositoryError.staleStorageRevision
    ) {
      _ = try await staleStorage.save(
        codec.encode(staleValue),
        replacing: staleRevision
      )
    }

    let reopened = try GlobalAuthorityRepository(
      storage: FileGlobalAuthorityStorage(fileURL: fileURL),
      initialSnapshot: initial
    )
    let persisted = try await reopened.current()
    #expect(persisted == deletionFence)
    #expect(
      persisted.preferences.profileSelection.profile.deletionEpoch.requestID
        == DeletionRequestID("delete-file")
    )
  }

  @Test("Conflict isolation and sensing revocation survive repository recreation")
  func conflictingFieldCannotBlockDurableSensingRevocation() async throws {
    let initial = GlobalAuthoritySnapshot(
      preferences: try makePreferences(
        sensingRevision: revision(1, "phone"),
        reminderRevision: revision(2, "shared"),
        reminderMode: .wristRaise
      ),
      consent: .disabled(
        revision: revision(1, "phone"),
        authorDevice: .phone
      )
    )
    let incoming = try makePreferences(
      sensingRevision: revision(5, "watch"),
      sensingEnabled: false,
      reminderRevision: revision(2, "shared"),
      reminderMode: .gentleHaptic
    )
    let storage = InMemoryGlobalAuthorityStorage()
    let first = try GlobalAuthorityRepository(
      storage: storage,
      initialSnapshot: initial
    )

    let result = try await first.merge(preferences: incoming)
    let persisted = try #require(result.value)

    #expect(!persisted.companionSensing.value.enabled)
    #expect(persisted.companionSensing.revision == revision(5, "watch"))

    let reopened = try GlobalAuthorityRepository(
      storage: storage,
      initialSnapshot: initial
    )
    let relaunched = try await reopened.current().preferences

    #expect(relaunched == persisted)
    #expect(!relaunched.companionSensing.value.enabled)
  }

  @Test("Codec rejects future schemas, undeclared fields, and oversized state")
  func codecFailsClosed() throws {
    let snapshot = try makeSnapshot()
    let codec = GlobalAuthorityCodec()
    let valid = try codec.encode(snapshot)
    let object = try #require(
      JSONSerialization.jsonObject(with: valid) as? [String: Any]
    )

    var future = object
    future["schemaVersion"] = 99
    let futureData = try JSONSerialization.data(withJSONObject: future)
    #expect(throws: GlobalAuthorityCodecError.invalidSnapshot) {
      try codec.decode(futureData)
    }

    var forgedBootstrap = object
    var forgedPreferences = try #require(
      forgedBootstrap["preferences"] as? [String: Any]
    )
    var forgedSelection = try #require(
      forgedPreferences["profileSelection"] as? [String: Any]
    )
    var forgedProfile = try #require(
      forgedSelection["profile"] as? [String: Any]
    )
    var forgedDeletion = try #require(
      forgedProfile["deletionEpoch"] as? [String: Any]
    )
    forgedDeletion["revision"] = [
      "counter": 2,
      "originDeviceID": "attacker",
    ]
    forgedProfile["deletionEpoch"] = forgedDeletion
    forgedSelection["profile"] = forgedProfile
    forgedPreferences["profileSelection"] = forgedSelection
    forgedBootstrap["preferences"] = forgedPreferences
    let forgedBootstrapData = try JSONSerialization.data(
      withJSONObject: forgedBootstrap,
      options: [.sortedKeys]
    )
    #expect(throws: GlobalAuthorityCodecError.invalidSnapshot) {
      try codec.decode(forgedBootstrapData)
    }

    var injected = object
    injected["deviceLocalNotificationPermission"] = "authorized"
    let injectedData = try JSONSerialization.data(withJSONObject: injected)
    #expect(
      throws: GlobalAuthorityCodecError.undeclaredField(
        "$.deviceLocalNotificationPermission"
      )
    ) {
      try codec.decode(injectedData)
    }

    let leadingWhitespace = Data(" \n".utf8) + valid
    #expect(throws: GlobalAuthorityCodecError.nonCanonical) {
      try codec.decode(leadingWhitespace)
    }

    let consentData = try JSONSerialization.data(
      withJSONObject: try #require(object["consent"]),
      options: [.sortedKeys]
    )
    let preferencesData = try JSONSerialization.data(
      withJSONObject: try #require(object["preferences"]),
      options: [.sortedKeys]
    )
    let reordered = Data(
      """
      {"schemaVersion":1,"preferences":\(String(decoding: preferencesData, as: UTF8.self)),"consent":\(String(decoding: consentData, as: UTF8.self))}
      """.utf8
    )
    #expect(throws: GlobalAuthorityCodecError.nonCanonical) {
      try codec.decode(reordered)
    }

    #expect(
      throws: GlobalAuthorityCodecError.oversized(
        actualBytes: valid.count,
        maximumBytes: valid.count - 1
      )
    ) {
      try GlobalAuthorityCodec(maximumBytes: valid.count - 1).decode(valid)
    }
  }

  @Test("Codec migrates and persists only an authentic legacy Mock bootstrap")
  func codecMigratesStrictLegacyMockBootstrap() async throws {
    let scenarioID = MockScenarioID("ordinary-day")
    let selectionRevision = revision(42, "watch")
    let epoch = ProfileEpoch(selectionRevision)
    let legacyProfile = RuntimeProfile(
      id: MockProfileBootstrapMigration.derivedProfileID(
        scenarioID: scenarioID,
        revision: selectionRevision
      ),
      epoch: epoch,
      deletionEpoch: DeletionEpoch(
        requestID:
          MockProfileBootstrapMigration.legacyDeletionRequestID(
            scenarioID: scenarioID,
            revision: selectionRevision
          ),
        revision: selectionRevision
      ),
      source: .mock(
        scenarioID: scenarioID,
        selectionEpoch: epoch
      )
    )
    let base = try makePreferences()
    let snapshot = GlobalAuthoritySnapshot(
      preferences: GlobalSyncedPreferences(
        profileSelection: ProfileSelectionRecord(
          profile: legacyProfile,
          revision: selectionRevision
        ),
        companionSensing: base.companionSensing,
        reminderMode: base.reminderMode,
        quietHours: base.quietHours
      ),
      consent: .disabled(
        revision: revision(1, "phone"),
        authorDevice: .phone
      )
    )
    let codec = GlobalAuthorityCodec()
    let data = try CanonicalJSONCodec().encode(snapshot)

    let decoded = try codec.decode(data)

    #expect(snapshot.isValid == false)
    #expect(decoded.isValid)
    #expect(decoded.deletionRoot == .bootstrap)
    #expect(
      decoded.preferences.profileSelection.profile.deletionEpoch == .bootstrap
    )

    let storage = InMemoryGlobalAuthorityStorage(data: data)
    let repository = try GlobalAuthorityRepository(
      storage: storage,
      initialSnapshot: try makeSnapshot()
    )
    #expect(try await repository.current() == decoded)
    #expect(try await storage.load().data == codec.encode(decoded))

    let digest = String(repeating: "a", count: 64)
    let forgedProfile = RuntimeProfile(
      id: ProfileID("mock-profile-\(digest)"),
      epoch: epoch,
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("mock-baseline-\(digest)"),
        revision: selectionRevision
      ),
      source: legacyProfile.source
    )
    let forged = GlobalAuthoritySnapshot(
      preferences: GlobalSyncedPreferences(
        profileSelection: ProfileSelectionRecord(
          profile: forgedProfile,
          revision: selectionRevision
        ),
        companionSensing: base.companionSensing,
        reminderMode: base.reminderMode,
        quietHours: base.quietHours
      ),
      consent: snapshot.consent
    )
    let forgedData = try CanonicalJSONCodec().encode(forged)
    #expect(throws: GlobalAuthorityCodecError.invalidSnapshot) {
      try codec.decode(forgedData)
    }
  }

  private func makeSnapshot(
    preferences: GlobalSyncedPreferences? = nil
  ) throws -> GlobalAuthoritySnapshot {
    GlobalAuthoritySnapshot(
      preferences: try preferences ?? makePreferences(),
      consent: .disabled(
        revision: revision(1, "phone"),
        authorDevice: .phone
      )
    )
  }

  private func makeDeletionSnapshot(
    revision deletionRevision: LamportRevision,
    requestID: String
  ) throws -> GlobalAuthoritySnapshot {
    let profile = RuntimeProfile(
      id: ProfileID("real"),
      epoch: ProfileEpoch(deletionRevision),
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID(requestID),
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
      consent: .disabled(
        revision: deletionRevision,
        authorDevice: .phone
      )
    )
  }

  private func makePreferences(
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

  private func revision(_ counter: UInt64, _ device: String) -> LamportRevision {
    LamportRevision(counter: counter, originDeviceID: device)
  }
}

extension GlobalPreferenceMergeResult {
  fileprivate var value: GlobalSyncedPreferences? {
    switch self {
    case .applied(let value), .duplicate(let value):
      value
    case .rejected:
      nil
    }
  }
}

private actor PausingGlobalAuthorityStorage: GlobalAuthorityStorage {
  private var data: Data?
  private var shouldPauseNextSave = false
  private var saveIsPaused = false
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

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
    if shouldPauseNextSave {
      shouldPauseNextSave = false
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
    guard GlobalAuthorityStorageRevision.current(for: self.data) == expectedRevision else {
      throw GlobalAuthorityRepositoryError.staleStorageRevision
    }
    self.data = data
    return .current(for: data)
  }

  func pauseNextSave() {
    shouldPauseNextSave = true
  }

  func waitUntilSaveIsPaused() async {
    guard saveIsPaused == false else { return }
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
