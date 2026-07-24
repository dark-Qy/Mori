import Foundation
import MoriDomain
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
    _ = try await first.merge(consent: incomingConsent)

    let reopened = try GlobalAuthorityRepository(
      storage: storage,
      initialSnapshot: initial
    )
    let value = try await reopened.current()

    #expect(value.preferences.reminderMode.value == .gentleHaptic)
    #expect(value.consent.dailyMemoryNotifications.enabled)
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

  private func makeSnapshot() throws -> GlobalAuthoritySnapshot {
    GlobalAuthoritySnapshot(
      preferences: try makePreferences(),
      consent: .disabled(
        revision: revision(1, "phone"),
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

  func load() -> Data? {
    data
  }

  func save(_ data: Data) async {
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
    }
    self.data = data
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
