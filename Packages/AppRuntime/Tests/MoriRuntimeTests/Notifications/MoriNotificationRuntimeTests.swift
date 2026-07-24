import Foundation
import MoriDomain
import Testing

@testable import MoriRuntime

@Suite("Mori notification runtime")
struct MoriNotificationRuntimeTests {
  private let now = ExperienceTestFixtures.date("2026-07-24T14:00:00Z")

  @Test("Scheduling requires iPhone, global consent, per-kind consent, and OS authorization")
  func authorityAndConsentGates() throws {
    let fixtures = try makeFixtures()
    let policy = MoriNotificationPolicy()

    #expect(
      policy.plan(
        memory: fixtures.memory,
        context: context(
          at: now,
          role: .watch,
          consent: consentState()
        )
      ) == .suppressed(.watchIsNotAuthority)
    )
    #expect(
      policy.plan(
        memory: fixtures.memory,
        context: context(
          at: now,
          consent: consentState(proactive: false)
        )
      ) == .suppressed(.consentDisabled)
    )
    #expect(
      policy.plan(
        letter: fixtures.letter,
        context: context(
          at: now,
          consent: consentState(letter: false)
        )
      ) == .suppressed(.consentDisabled)
    )
    #expect(
      policy.plan(
        letter: fixtures.letter,
        context: context(
          at: now,
          consent: consentState(),
          authorization: .denied
        )
      ) == .suppressed(.localAuthorizationUnavailable)
    )
    #expect(
      policy.plan(
        memory: fixtures.memory,
        context: context(
          at: now.addingTimeInterval(-60),
          consent: consentState()
        )
      ) == .suppressed(.invalidContent)
    )

    let plannedRequest = try #require(
      request(
        from: policy.plan(
          letter: fixtures.letter,
          context: context(at: now, consent: consentState())
        )
      )
    )
    #expect(
      MoriNotificationRouteResolver().resolve(
        plannedRequest.route,
        state: fixtures.state
      ) == .letter(fixtures.letter.header.recordID)
    )
    #expect(fixtures.state.tasks.isEmpty)
    #expect(fixtures.state.coinLedger.balance == 0)
  }

  @Test("Frozen daily and six-hour budgets survive local-day boundaries")
  func frozenBudget() throws {
    let policy = MoriNotificationRuntimePolicy()
    let memory = request(
      kind: .dailyMemory,
      objectID: "memory-one",
      at: ExperienceTestFixtures.date("2026-07-24T14:00:00Z")
    )
    let letter = request(
      kind: .letter,
      objectID: "letter-one",
      at: ExperienceTestFixtures.date("2026-07-24T14:30:00Z")
    )
    var snapshot = try #require(
      policy.inserting(memory, into: MoriNotificationSnapshot()).value
    )
    snapshot = try #require(
      policy.inserting(letter, into: snapshot).value
    )

    #expect(
      policy.inserting(
        request(
          kind: .dailyMemory,
          objectID: "memory-three",
          at: ExperienceTestFixtures.date("2026-07-24T15:00:00Z")
        ),
        into: snapshot
      ) == .failure(.totalDailyBudget)
    )

    let oneLetterOnly = try #require(
      policy.inserting(letter, into: MoriNotificationSnapshot()).value
    )
    #expect(
      policy.inserting(
        request(
          kind: .letter,
          objectID: "letter-two",
          at: ExperienceTestFixtures.date("2026-07-24T15:30:00Z")
        ),
        into: oneLetterOnly
      ) == .failure(.kindDailyBudget)
    )

    let lateLetter = request(
      kind: .letter,
      objectID: "late-letter",
      at: ExperienceTestFixtures.date("2026-07-24T15:00:00Z")
    )
    let lateSnapshot = try #require(
      policy.inserting(lateLetter, into: MoriNotificationSnapshot()).value
    )
    let nextDayTooSoon = request(
      kind: .letter,
      objectID: "next-day-too-soon",
      at: ExperienceTestFixtures.date("2026-07-24T17:00:00Z")
    )
    #expect(
      nextDayTooSoon.budgetDay == LocalDay("2026-07-25")
    )
    #expect(
      policy.inserting(nextDayTooSoon, into: lateSnapshot)
        == .failure(.cooldown)
    )
    #expect(
      policy.inserting(
        request(
          kind: .letter,
          objectID: "next-day-eligible",
          at: ExperienceTestFixtures.date("2026-07-24T22:00:00Z")
        ),
        into: lateSnapshot
      ).value != nil
    )
  }

  @Test("Clock rollback cannot reopen an already consumed daily budget")
  func rollbackFence() throws {
    let policy = MoriNotificationRuntimePolicy()
    let current = request(
      kind: .dailyMemory,
      objectID: "current",
      at: now
    )
    let snapshot = try #require(
      policy.inserting(current, into: MoriNotificationSnapshot()).value
    )
    let rollback = request(
      kind: .letter,
      objectID: "rollback",
      at: now.addingTimeInterval(-60)
    )

    #expect(
      policy.inserting(rollback, into: snapshot)
        == .failure(.clockRollback)
    )
  }

  @Test("History rollover retains every active delivered request")
  func historyRolloverPreservesActiveRequests() throws {
    let policy = MoriNotificationRuntimePolicy()
    let oldDelivered = request(
      kind: .letter,
      objectID: "long-unread-letter",
      at: now
    )
    let seeded = try #require(
      policy.inserting(
        oldDelivered,
        into: MoriNotificationSnapshot()
      ).value
    )
    var snapshot = MoriNotificationSnapshot(
      delivered: [oldDelivered],
      history: seeded.history,
      commands: []
    )

    for day in 1...130 {
      let next = request(
        kind: .letter,
        objectID: "rollover-letter-\(day)",
        at: now.addingTimeInterval(Double(day) * 24 * 60 * 60)
      )
      let inserted = try #require(
        policy.inserting(next, into: snapshot).value
      )
      #expect(inserted.isValid)
      snapshot = MoriNotificationSnapshot(
        delivered: [oldDelivered],
        history: inserted.history,
        commands: []
      )
      #expect(snapshot.isValid)
    }

    #expect(
      snapshot.history.count
        == MoriNotificationSnapshot.maximumHistoryCount
    )
    #expect(
      snapshot.history.contains {
        $0.stableRequestID == oldDelivered.stableRequestID
          && $0.scheduledAt == oldDelivered.scheduledAt
      }
    )
    #expect(
      policy.inserting(
        request(
          kind: .letter,
          objectID: "rollover-still-operational",
          at: now.addingTimeInterval(131 * 24 * 60 * 60)
        ),
        into: snapshot
      ).value?.isValid == true
    )
  }

  @Test("Schedule remains in a durable OS command outbox until acknowledged")
  func durableScheduleCommand() async throws {
    let fixtures = try makeFixtures()
    let storage = InMemoryMoriNotificationSnapshotStorage()
    let runtime = MoriNotificationRuntime(storage: storage)
    let scheduleContext = context(at: now, consent: consentState())
    let first = try #require(
      try await runtime.schedule(
        memory: fixtures.memory,
        state: fixtures.state,
        context: scheduleContext
      ).value
    )
    let command = try #require(first.commands.first)
    guard case .schedule = command.action else {
      Issue.record("Expected a durable schedule command")
      return
    }

    let relaunched = MoriNotificationRuntime(storage: storage)
    #expect(try await relaunched.nextCommand() == command)
    let retried = try #require(
      try await relaunched.schedule(
        memory: fixtures.memory,
        state: fixtures.state,
        context: scheduleContext
      ).value
    )
    #expect(retried.commands == [command])

    _ = try await relaunched.acknowledge(
      operationID: command.operationID
    )
    #expect(try await relaunched.nextCommand() == nil)
    #expect(try await relaunched.current().pending.count == 1)
  }

  @Test("Consent revocation and read state remain durable cancel commands")
  func durableCancellation() async throws {
    let fixtures = try makeFixtures()
    let storage = InMemoryMoriNotificationSnapshotStorage()
    let runtime = MoriNotificationRuntime(storage: storage)
    let plan = MoriNotificationPolicy().plan(
      letter: fixtures.letter,
      context: context(at: now, consent: consentState())
    )
    let scheduled = try #require(
      try await runtime.schedule(
        letter: fixtures.letter,
        state: fixtures.state,
        context: context(at: now, consent: consentState())
      ).value
    )
    for command in scheduled.commands {
      _ = try await runtime.acknowledge(operationID: command.operationID)
    }
    _ = try await runtime.markDelivered(
      stableRequestID: try #require(request(from: plan)).stableRequestID
    )
    #expect(try await runtime.current().pending.isEmpty)
    #expect(try await runtime.current().delivered.count == 1)

    var readLetter = fixtures.letter
    #expect(
      readLetter.apply(
        LetterTransition(
          header: ExperienceTestFixtures.header(
            LetterTransitionID("read-letter"),
            profile: fixtures.state.runtimeProfile
          ),
          letterID: readLetter.header.recordID,
          revision: ExperienceTestFixtures.revision(80),
          kind: .read(at: now.addingTimeInterval(60))
        ),
        in: fixtures.state.runtimeProfile
      ) == .applied
    )
    let state = replacing(
      fixtures.state,
      memories: fixtures.state.memories,
      letters: [readLetter]
    )
    let deliveredRelaunch = MoriNotificationRuntime(storage: storage)
    #expect(try await deliveredRelaunch.current().delivered.count == 1)
    let mutation = try await deliveredRelaunch.reconcile(
      state: state,
      consent: consentState(),
      localAuthorization: .authorized
    )
    let cancel = try #require(mutation.commands.first)
    guard case .cancel(let requestID, _) = cancel.action else {
      Issue.record("Expected a durable cancel command")
      return
    }
    let plannedRequest = try #require(request(from: plan))
    #expect(
      requestID == plannedRequest.stableRequestID
    )
    _ = try await deliveredRelaunch.markDelivered(
      stableRequestID: requestID
    )
    #expect(try await deliveredRelaunch.nextCommand() == cancel)

    let relaunched = MoriNotificationRuntime(storage: storage)
    #expect(try await relaunched.nextCommand() == cancel)
    _ = try await relaunched.acknowledge(operationID: cancel.operationID)
    #expect(try await relaunched.nextCommand() == nil)
  }

  @Test("Scheduling atomically revalidates current consent and object state")
  func scheduleRevalidatesAuthority() async throws {
    let fixtures = try makeFixtures()
    let runtime = MoriNotificationRuntime(
      storage: InMemoryMoriNotificationSnapshotStorage()
    )

    #expect(
      try await runtime.schedule(
        letter: fixtures.letter,
        state: fixtures.state,
        context: context(
          at: now,
          consent: consentState(proactive: false)
        )
      ) == .failure(.consentDisabled)
    )
    #expect(try await runtime.nextCommand() == nil)

    var readLetter = fixtures.letter
    #expect(
      readLetter.apply(
        LetterTransition(
          header: ExperienceTestFixtures.header(
            LetterTransitionID("already-read"),
            profile: fixtures.state.runtimeProfile
          ),
          letterID: readLetter.header.recordID,
          revision: ExperienceTestFixtures.revision(81),
          kind: .read(at: now)
        ),
        in: fixtures.state.runtimeProfile
      ) == .applied
    )
    let readState = replacing(
      fixtures.state,
      memories: fixtures.state.memories,
      letters: [readLetter]
    )
    #expect(
      try await runtime.schedule(
        letter: fixtures.letter,
        state: readState,
        context: context(at: now, consent: consentState())
      ) == .failure(.invalidContent)
    )
    #expect(try await runtime.nextCommand() == nil)
  }

  @Test("Only the FIFO command may execute or be acknowledged")
  func commandOrdering() async throws {
    let fixtures = try makeFixtures()
    let runtime = MoriNotificationRuntime(
      storage: InMemoryMoriNotificationSnapshotStorage()
    )
    let first = try #require(
      try await runtime.schedule(
        letter: fixtures.letter,
        state: fixtures.state,
        context: context(at: now, consent: consentState())
      ).value
    )
    let schedule = try #require(first.commands.first)
    _ = try await runtime.acknowledge(operationID: schedule.operationID)

    var readLetter = fixtures.letter
    #expect(
      readLetter.apply(
        LetterTransition(
          header: ExperienceTestFixtures.header(
            LetterTransitionID("read-before-reschedule"),
            profile: fixtures.state.runtimeProfile
          ),
          letterID: readLetter.header.recordID,
          revision: ExperienceTestFixtures.revision(82),
          kind: .read(at: now.addingTimeInterval(1))
        ),
        in: fixtures.state.runtimeProfile
      ) == .applied
    )
    let readState = replacing(
      fixtures.state,
      memories: fixtures.state.memories,
      letters: [readLetter]
    )
    let cancellation = try await runtime.reconcile(
      state: readState,
      consent: consentState(),
      localAuthorization: .authorized
    )
    let cancel = try #require(cancellation.commands.first)

    let nextDay = now.addingTimeInterval(24 * 60 * 60)
    let rescheduled = try #require(
      try await runtime.schedule(
        letter: fixtures.letter,
        state: fixtures.state,
        context: context(at: nextDay, consent: consentState())
      ).value
    )
    #expect(rescheduled.commands == [cancel])
    let plannedRequest = try #require(
      request(
        from: MoriNotificationPolicy().plan(
          letter: fixtures.letter,
          context: context(
            at: nextDay,
            consent: consentState()
          )
        )
      )
    )
    let laterSchedule = MoriNotificationCommand.make(
      sequence: cancel.sequence + 1,
      action: .schedule(plannedRequest)
    )

    await #expect(
      throws: MoriNotificationRuntimeError.outOfOrderAcknowledgement(
        expectedOperationID: cancel.operationID,
        receivedOperationID: laterSchedule.operationID
      )
    ) {
      try await runtime.acknowledge(
        operationID: laterSchedule.operationID
      )
    }
    _ = try await runtime.acknowledge(operationID: cancel.operationID)
    #expect(try await runtime.nextCommand() == laterSchedule)
  }

  @Test("Revised sealed content cancels an obsolete notification request")
  func revisedMemoryCancellation() async throws {
    let fixtures = try makeFixtures()
    let storage = InMemoryMoriNotificationSnapshotStorage()
    let runtime = MoriNotificationRuntime(storage: storage)
    let scheduled = try #require(
      try await runtime.schedule(
        memory: fixtures.memory,
        state: fixtures.state,
        context: context(at: now, consent: consentState())
      ).value
    )
    for command in scheduled.commands {
      _ = try await runtime.acknowledge(operationID: command.operationID)
    }

    let revised = MemoryRecord(
      header: fixtures.memory.header,
      localDay: fixtures.memory.localDay,
      timeZoneIdentifier: fixtures.memory.timeZoneIdentifier,
      authoredRevision: ExperienceTestFixtures.revision(99),
      lifecycle: fixtures.memory.lifecycle,
      winningTransitionID: fixtures.memory.winningTransitionID
    )
    let state = replacing(
      fixtures.state,
      memories: [revised],
      letters: [fixtures.letter]
    )
    #expect(state.validate() == nil)
    let mutation = try await runtime.reconcile(
      state: state,
      consent: consentState(),
      localAuthorization: .authorized
    )

    #expect(mutation.snapshot.pending.isEmpty)
    #expect(mutation.commands.count == 1)
    guard case .cancel = mutation.commands[0].action else {
      Issue.record("Expected revised content to cancel the old request")
      return
    }
  }

  @Test("Suspended storage serializes concurrent scheduling")
  func concurrentPersistence() async throws {
    let fixtures = try makeFixtures()
    let storage = PausingMoriNotificationStorage()
    let runtime = MoriNotificationRuntime(storage: storage)
    await storage.pauseNextSave()
    let first = Task {
      try await runtime.schedule(
        memory: fixtures.memory,
        state: fixtures.state,
        context: context(at: now, consent: consentState())
      )
    }
    await storage.waitUntilSaveIsPaused()
    let second = Task {
      try await runtime.schedule(
        letter: fixtures.letter,
        state: fixtures.state,
        context: context(
          at: now.addingTimeInterval(60),
          consent: consentState()
        )
      )
    }
    await storage.releaseSave()
    _ = try await first.value
    _ = try await second.value

    let snapshot = try await runtime.current()
    #expect(Set(snapshot.pending.map(\.kind)) == [.dailyMemory, .letter])
    let firstCommand = try #require(try await runtime.nextCommand())
    _ = try await runtime.acknowledge(
      operationID: firstCommand.operationID
    )
    let secondCommand = try #require(try await runtime.nextCommand())
    #expect(secondCommand.operationID != firstCommand.operationID)
    _ = try await runtime.acknowledge(
      operationID: secondCommand.operationID
    )
    #expect(try await runtime.nextCommand() == nil)
  }

  @Test("Codec rejects injected fields, oversized data, and malformed command identity")
  func codecFailsClosed() throws {
    let candidate = request(
      kind: .letter,
      objectID: "codec-letter",
      at: now
    )
    let inserted = try #require(
      MoriNotificationRuntimePolicy().inserting(
        candidate,
        into: MoriNotificationSnapshot()
      ).value
    )
    let command = MoriNotificationCommand.make(
      sequence: 1,
      action: .schedule(candidate)
    )
    let snapshot = MoriNotificationSnapshot(
      pending: inserted.pending,
      history: inserted.history,
      commands: [command],
      nextCommandSequence: 2
    )
    let codec = MoriNotificationSnapshotCodec()
    let data = try codec.encode(snapshot)
    #expect(!MoriNotificationSnapshot(schemaVersion: 1).isValid)
    let orphanedPending = MoriNotificationSnapshot(
      pending: [candidate]
    )
    #expect(!orphanedPending.isValid)
    #expect(throws: MoriNotificationSnapshotCodecError.invalidSnapshot) {
      try codec.encode(orphanedPending)
    }
    #expect(throws: MoriNotificationSnapshotCodecError.malformed) {
      try codec.decode(Data([0x20]) + data)
    }
    var object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["settleTask"] = true
    let injected = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: MoriNotificationSnapshotCodecError.malformed) {
      try codec.decode(injected)
    }
    #expect(throws: MoriNotificationSnapshotCodecError.oversized) {
      try MoriNotificationSnapshotCodec(maximumBytes: data.count - 1)
        .decode(data)
    }
    #expect(
      !MoriNotificationSnapshot(
        pending: inserted.pending,
        history: inserted.history,
        commands: [
          MoriNotificationCommand(
            operationID: "forged",
            sequence: 1,
            action: .schedule(candidate)
          )
        ],
        nextCommandSequence: 2
      ).isValid
    )

    let wrongDay = replacing(
      candidate,
      budgetDay: LocalDay("2026-07-25")
    )
    #expect(!MoriNotificationSnapshot(pending: [wrongDay]).isValid)

    let mismatchedPayload = replacing(
      candidate,
      body: "Different body"
    )
    #expect(
      !MoriNotificationSnapshot(
        pending: [candidate],
        history: inserted.history,
        commands: [
          MoriNotificationCommand.make(
            sequence: 1,
            action: .schedule(mismatchedPayload)
          )
        ],
        nextCommandSequence: 2
      ).isValid
    )
  }

  @Test("Protected file storage preserves commands across multiple commits")
  func protectedFileStorage() async throws {
    let fixtures = try makeFixtures()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "mori-notification-\(UUID().uuidString)",
        isDirectory: true
      )
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let storage = FileMoriNotificationSnapshotStorage(
      fileURL: directory.appendingPathComponent("outbox.json")
    )
    let runtime = MoriNotificationRuntime(storage: storage)
    let scheduled = try #require(
      try await runtime.schedule(
        memory: fixtures.memory,
        state: fixtures.state,
        context: context(at: now, consent: consentState())
      ).value
    )
    let command = try #require(scheduled.commands.first)
    _ = try await runtime.acknowledge(operationID: command.operationID)

    let relaunched = MoriNotificationRuntime(storage: storage)
    #expect(try await relaunched.current().pending.count == 1)
    #expect(try await relaunched.nextCommand() == nil)
    let cancellation = try await relaunched.cancelAll()
    let cancel = try #require(cancellation.commands.first)

    let reopened = MoriNotificationRuntime(storage: storage)
    #expect(try await reopened.nextCommand() == cancel)
  }

  private func makeFixtures() throws -> (
    state: ProfileState,
    memory: MemoryRecord,
    letter: LetterRecord
  ) {
    let fact = ExperienceTestFixtures.fact(
      "notification-steps",
      observedAt: now.addingTimeInterval(-3_600)
    )
    let event = ExperienceTestFixtures.event(
      "notification-walk",
      observedAt: fact.observedAt,
      fact: fact
    )
    let base = ExperienceTestFixtures.state(
      facts: [fact],
      events: [event]
    )
    let outcome = DailyMemoryCompositionPolicy().compose(
      state: base,
      at: now,
      timeZone: ExperienceTestFixtures.timeZone,
      deviceRole: .iPhone,
      authoredRevision: ExperienceTestFixtures.revision(50)
    )
    guard case .sealed(let memory) = outcome else {
      throw FixtureError.missingMemory
    }
    let letter = LetterRecord(
      header: ExperienceTestFixtures.header(
        LetterID("letter-evening"),
        profile: base.runtimeProfile
      ),
      source: .memory(memory.header.recordID),
      title: "Mori 留了一封信",
      body: "今天走过的那段路，我记住了。",
      deliveredAt: now,
      authoredRevision: ExperienceTestFixtures.revision(60)
    )
    let state = replacing(
      base,
      memories: [memory],
      letters: [letter]
    )
    #expect(state.validate() == nil)
    return (state, memory, letter)
  }

  private func replacing(
    _ state: ProfileState,
    memories: [MemoryRecord],
    letters: [LetterRecord]
  ) -> ProfileState {
    ProfileState(
      header: state.header,
      runtimeProfile: state.runtimeProfile,
      companionSensingEnabled: state.companionSensingEnabled,
      currentSensingEpoch: state.currentSensingEpoch,
      selectedIdentity: state.selectedIdentity,
      identityRevision: state.identityRevision,
      tone: state.tone,
      derivedFacts: state.derivedFacts,
      passiveEvents: state.passiveEvents,
      tasks: state.tasks,
      cooldowns: state.cooldowns,
      coinLedger: state.coinLedger,
      collection: state.collection,
      memories: memories,
      letters: letters,
      conversation: state.conversation,
      experienceLedger: state.experienceLedger
    )
  }

  private func context(
    at date: Date,
    role: DailyMemoryDeviceRole = .iPhone,
    consent: GlobalConsentState,
    authorization: MoriNotificationAuthorization = .authorized
  ) -> MoriNotificationSchedulingContext {
    MoriNotificationSchedulingContext(
      activeProfile: ExperienceTestFixtures.profile(),
      deviceRole: role,
      consent: consent,
      localAuthorization: authorization,
      quietHours: CompanionQuietHours(
        startMinute: 9 * 60,
        endMinute: 17 * 60
      ),
      timeZone: ExperienceTestFixtures.timeZone,
      now: date
    )
  }

  private func consentState(
    proactive: Bool = true,
    daily: Bool = true,
    letter: Bool = true
  ) -> GlobalConsentState {
    let disabled = GlobalConsentState.disabled(
      revision: ExperienceTestFixtures.revision(1),
      authorDevice: .phone
    )
    return
      disabled
      .replacing(
        .proactiveNotifications,
        with: proactive
          ? enabledRecord(.proactiveNotifications)
          : disabled.proactiveNotifications
      )
      .replacing(
        .dailyMemoryNotifications,
        with: daily
          ? enabledRecord(.dailyMemoryNotifications)
          : disabled.dailyMemoryNotifications
      )
      .replacing(
        .letterNotifications,
        with: letter
          ? enabledRecord(.letterNotifications)
          : disabled.letterNotifications
      )
  }

  private func enabledRecord(
    _ kind: MoriConsentKind
  ) -> MoriConsentRecord {
    MoriConsentRecord(
      enabled: true,
      disclosureVersion: kind.requiredDisclosureVersion,
      revision: ExperienceTestFixtures.revision(70),
      authorDevice: .phone
    )
  }

  private func request(
    from plan: MoriNotificationCandidatePlan
  ) -> MoriNotificationRequest? {
    guard case .schedule(let request) = plan else { return nil }
    return request
  }

  private func request(
    kind: MoriNotificationKind,
    objectID: String,
    at date: Date
  ) -> MoriNotificationRequest {
    let profile = ExperienceTestFixtures.profile()
    return MoriNotificationRequest(
      stableRequestID: MoriNotificationRequestIdentity.make(
        kind: kind,
        profileID: profile.id,
        profileEpoch: profile.epoch,
        objectID: objectID
      ),
      kind: kind,
      title: "Title",
      body: "Body",
      route: MoriNotificationRoute(
        kind: kind,
        profileID: profile.id,
        profileEpoch: profile.epoch,
        objectID: objectID
      ),
      profileDeletionEpoch: profile.deletionEpoch,
      contentRevision: ExperienceTestFixtures.revision(50),
      budgetDay: MoriNotificationLocalDay.resolve(
        date,
        timeZone: ExperienceTestFixtures.timeZone
      ),
      timeZoneIdentifier: ExperienceTestFixtures.timeZone.identifier,
      scheduledAt: date
    )
  }

  private func replacing(
    _ request: MoriNotificationRequest,
    budgetDay: LocalDay? = nil,
    body: String? = nil
  ) -> MoriNotificationRequest {
    MoriNotificationRequest(
      stableRequestID: request.stableRequestID,
      kind: request.kind,
      title: request.title,
      body: body ?? request.body,
      route: request.route,
      profileDeletionEpoch: request.profileDeletionEpoch,
      contentRevision: request.contentRevision,
      budgetDay: budgetDay ?? request.budgetDay,
      timeZoneIdentifier: request.timeZoneIdentifier,
      scheduledAt: request.scheduledAt
    )
  }

  private enum FixtureError: Error {
    case missingMemory
  }
}

extension Result {
  fileprivate var value: Success? {
    guard case .success(let value) = self else { return nil }
    return value
  }
}

private actor PausingMoriNotificationStorage:
  MoriNotificationSnapshotStorage
{
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
