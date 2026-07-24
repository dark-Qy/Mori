import Foundation
import MoriDomain
import Testing

@testable import MoriRuntime

@Suite("Pending companion glance")
struct PendingGlanceRuntimeTests {
  private let nonQuietHours = CompanionQuietHours(
    startMinute: 9 * 60,
    endMinute: 17 * 60
  )

  @Test("The newest event replaces the old slot and is presented only once")
  func replacementAndSinglePresentation() async throws {
    let now = ExperienceTestFixtures.date("2026-07-24T12:00:00Z")
    let olderFact = ExperienceTestFixtures.fact(
      "older-fact",
      observedAt: now.addingTimeInterval(-60)
    )
    let newerFact = ExperienceTestFixtures.fact(
      "newer-fact",
      observedAt: now.addingTimeInterval(-15)
    )
    let older = ExperienceTestFixtures.event(
      "older",
      observedAt: olderFact.observedAt,
      fact: olderFact
    )
    let newer = ExperienceTestFixtures.event(
      "newer",
      observedAt: newerFact.observedAt,
      fact: newerFact,
      kind: .fastPace
    )
    let clock = DeterministicMockExperienceClock(now: now)
    let runtime = PendingGlanceRuntime(
      clock: clock,
      storage: InMemoryPendingGlancePresentationFenceStorage()
    )

    let first = try await runtime.foregroundActivation(
      events: [newer, older],
      activeProfile: ExperienceTestFixtures.profile(),
      currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
      reminderMode: .gentleHaptic,
      quietHours: nonQuietHours,
      timeZone: ExperienceTestFixtures.timeZone
    )
    #expect(first.presentation?.eventID == newer.header.recordID)
    #expect(first.presentation?.eventKind == .fastPace)
    #expect(first.terminalDecisions.count == 2)
    #expect(
      first.terminalDecisions.contains {
        $0.eventID == older.header.recordID
          && $0.state == .replaced(by: newer.header.recordID, at: now)
      }
    )
    #expect(
      first.terminalDecisions.contains {
        $0.eventID == newer.header.recordID
          && $0.state == .presented(at: now)
      }
    )

    let repeated = try await runtime.foregroundActivation(
      events: [older, newer],
      activeProfile: ExperienceTestFixtures.profile(),
      currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
      reminderMode: .gentleHaptic,
      quietHours: nonQuietHours,
      timeZone: ExperienceTestFixtures.timeZone
    )
    #expect(repeated == .empty)
  }

  @Test("A returned presentation remains consumed after relaunch")
  func relaunchDoesNotPresentAgain() async throws {
    let now = ExperienceTestFixtures.date("2026-07-24T12:00:00Z")
    let fact = ExperienceTestFixtures.fact(
      "relaunch-fact",
      observedAt: now.addingTimeInterval(-10)
    )
    let event = ExperienceTestFixtures.event(
      "relaunch-event",
      observedAt: fact.observedAt,
      fact: fact
    )
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "mori-pending-glance-\(UUID().uuidString)",
        isDirectory: true
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("fences.json")
    let storage = FilePendingGlancePresentationFenceStorage(
      fileURL: fileURL
    )

    let firstRuntime = PendingGlanceRuntime(
      clock: DeterministicMockExperienceClock(now: now),
      storage: storage
    )
    let first = try await firstRuntime.foregroundActivation(
      events: [event],
      activeProfile: ExperienceTestFixtures.profile(),
      currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
      reminderMode: .gentleHaptic,
      quietHours: nonQuietHours,
      timeZone: ExperienceTestFixtures.timeZone
    )
    #expect(first.presentation?.eventID == event.header.recordID)
    #expect(try #require(await storage.load()).isEmpty == false)

    // New storage and runtime instances over the protected file model process
    // termination immediately after the first UI received the presentation.
    let relaunchedStorage =
      FilePendingGlancePresentationFenceStorage(fileURL: fileURL)
    let relaunchedRuntime = PendingGlanceRuntime(
      clock: DeterministicMockExperienceClock(now: now),
      storage: relaunchedStorage
    )
    let relaunched = try await relaunchedRuntime.foregroundActivation(
      events: [event],
      activeProfile: ExperienceTestFixtures.profile(),
      currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
      reminderMode: .gentleHaptic,
      quietHours: nonQuietHours,
      timeZone: ExperienceTestFixtures.timeZone
    )
    #expect(relaunched == .empty)
  }

  @Test("Concurrent foreground activations expose one presentation")
  func concurrentActivationIsSerialized() async throws {
    let now = ExperienceTestFixtures.date("2026-07-24T12:00:00Z")
    let fact = ExperienceTestFixtures.fact(
      "concurrent-fact",
      observedAt: now.addingTimeInterval(-10)
    )
    let event = ExperienceTestFixtures.event(
      "concurrent-event",
      observedAt: fact.observedAt,
      fact: fact
    )
    let runtime = PendingGlanceRuntime(
      clock: DeterministicMockExperienceClock(now: now),
      storage: InMemoryPendingGlancePresentationFenceStorage()
    )
    let profile = ExperienceTestFixtures.profile()
    let plans = try await withThrowingTaskGroup(
      of: PendingGlancePlan.self
    ) { group in
      for _ in 0..<2 {
        group.addTask {
          try await runtime.foregroundActivation(
            events: [event],
            activeProfile: profile,
            currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
            reminderMode: .gentleHaptic,
            quietHours: self.nonQuietHours,
            timeZone: ExperienceTestFixtures.timeZone
          )
        }
      }
      var values: [PendingGlancePlan] = []
      for try await value in group {
        values.append(value)
      }
      return values
    }

    #expect(plans.filter { $0.presentation != nil }.count == 1)
    #expect(plans.filter { $0 == .empty }.count == 1)
  }

  @Test("A failed fence save returns no presentation and remains retryable")
  func saveFailureFailsClosed() async throws {
    let now = ExperienceTestFixtures.date("2026-07-24T12:00:00Z")
    let fact = ExperienceTestFixtures.fact(
      "failure-fact",
      observedAt: now.addingTimeInterval(-10)
    )
    let event = ExperienceTestFixtures.event(
      "failure-event",
      observedAt: fact.observedAt,
      fact: fact
    )
    let storage = ControllablePendingGlanceFenceStorage(
      shouldFailNextSave: true
    )
    let runtime = PendingGlanceRuntime(
      clock: DeterministicMockExperienceClock(now: now),
      storage: storage
    )

    do {
      _ = try await runtime.foregroundActivation(
        events: [event],
        activeProfile: ExperienceTestFixtures.profile(),
        currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
        reminderMode: .gentleHaptic,
        quietHours: nonQuietHours,
        timeZone: ExperienceTestFixtures.timeZone
      )
      Issue.record("A presentation must not escape a failed durable save")
    } catch is ControllablePendingGlanceFenceStorage.TestError {
      // The storage fails before its commit point.
    }
    #expect(await storage.load() == nil)

    let retried = try await runtime.foregroundActivation(
      events: [event],
      activeProfile: ExperienceTestFixtures.profile(),
      currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
      reminderMode: .gentleHaptic,
      quietHours: nonQuietHours,
      timeZone: ExperienceTestFixtures.timeZone
    )
    #expect(retried.presentation?.eventID == event.header.recordID)
  }

  @Test("Replacement fences both the old slot and newest presentation")
  func replacementSurvivesRelaunch() async throws {
    let now = ExperienceTestFixtures.date("2026-07-24T12:00:00Z")
    let olderFact = ExperienceTestFixtures.fact(
      "replacement-old-fact",
      observedAt: now.addingTimeInterval(-60)
    )
    let newerFact = ExperienceTestFixtures.fact(
      "replacement-new-fact",
      observedAt: now.addingTimeInterval(-10)
    )
    let older = ExperienceTestFixtures.event(
      "replacement-old",
      observedAt: olderFact.observedAt,
      fact: olderFact
    )
    let newer = ExperienceTestFixtures.event(
      "replacement-new",
      observedAt: newerFact.observedAt,
      fact: newerFact
    )
    let storage = InMemoryPendingGlancePresentationFenceStorage()
    let firstRuntime = PendingGlanceRuntime(
      clock: DeterministicMockExperienceClock(now: now),
      storage: storage
    )

    #expect(
      try await firstRuntime.foregroundActivation(
        events: [older, newer],
        activeProfile: ExperienceTestFixtures.profile(),
        currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
        reminderMode: .wristRaise,
        quietHours: nonQuietHours,
        timeZone: ExperienceTestFixtures.timeZone
      ).presentation?.eventID == newer.header.recordID
    )

    let relaunchedRuntime = PendingGlanceRuntime(
      clock: DeterministicMockExperienceClock(now: now),
      storage: storage
    )
    #expect(
      try await relaunchedRuntime.foregroundActivation(
        events: [older, newer],
        activeProfile: ExperienceTestFixtures.profile(),
        currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
        reminderMode: .wristRaise,
        quietHours: nonQuietHours,
        timeZone: ExperienceTestFixtures.timeZone
      ) == .empty
    )
  }

  @Test("Profile epoch and deletion epoch are independent fences")
  func profileScopeSeparatesFences() async throws {
    let now = ExperienceTestFixtures.date("2026-07-24T12:00:00Z")
    let originalProfile = ExperienceTestFixtures.profile()
    let newEpoch = ProfileEpoch(
      ExperienceTestFixtures.revision(11, device: "profile-authority")
    )
    let epochProfile = RuntimeProfile(
      id: originalProfile.id,
      epoch: newEpoch,
      deletionEpoch: originalProfile.deletionEpoch,
      source: .mock(
        scenarioID: MockScenarioID("normal-day"),
        selectionEpoch: newEpoch
      )
    )
    let deletionProfile = RuntimeProfile(
      id: originalProfile.id,
      epoch: newEpoch,
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("deletion-next"),
        revision: ExperienceTestFixtures.revision(
          2,
          device: "deletion-authority"
        )
      ),
      source: epochProfile.source
    )
    let storage = InMemoryPendingGlancePresentationFenceStorage()

    for (profile, suffix) in [
      (originalProfile, "original"),
      (epochProfile, "epoch"),
      (deletionProfile, "deletion"),
    ] {
      let fact = ExperienceTestFixtures.fact(
        "scoped-fact-\(suffix)",
        observedAt: now.addingTimeInterval(-10),
        profile: profile
      )
      let event = ExperienceTestFixtures.event(
        "same-scoped-event",
        observedAt: fact.observedAt,
        fact: fact,
        profile: profile
      )
      let runtime = PendingGlanceRuntime(
        clock: DeterministicMockExperienceClock(now: now),
        storage: storage
      )
      let plan = try await runtime.foregroundActivation(
        events: [event],
        activeProfile: profile,
        currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
        reminderMode: .wristRaise,
        quietHours: nonQuietHours,
        timeZone: ExperienceTestFixtures.timeZone
      )
      #expect(plan.presentation?.eventID == event.header.recordID)
    }

    let originalFact = ExperienceTestFixtures.fact(
      "scoped-fact-recheck",
      observedAt: now.addingTimeInterval(-10),
      profile: originalProfile
    )
    let originalEvent = ExperienceTestFixtures.event(
      "same-scoped-event",
      observedAt: originalFact.observedAt,
      fact: originalFact,
      profile: originalProfile
    )
    let relaunchedOriginal = PendingGlanceRuntime(
      clock: DeterministicMockExperienceClock(now: now),
      storage: storage
    )
    #expect(
      try await relaunchedOriginal.foregroundActivation(
        events: [originalEvent],
        activeProfile: originalProfile,
        currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
        reminderMode: .wristRaise,
        quietHours: nonQuietHours,
        timeZone: ExperienceTestFixtures.timeZone
      ) == .empty
    )
  }

  @Test("Fence payload is closed, canonical, versioned, and bounded")
  func fenceCodecBoundaries() throws {
    let profile = ExperienceTestFixtures.profile()
    let snapshot = PendingGlancePresentationFenceSnapshot(
      scopes: [
        PendingGlancePresentationFenceScope(
          profile: profile,
          terminalEventIDs: [EventID("event")]
        )
      ]
    )
    let codec = PendingGlancePresentationFenceCodec()
    let data = try codec.encode(snapshot)
    #expect(try codec.decode(data) == snapshot)

    var object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["undeclared"] = true
    let undeclared = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys]
    )
    #expect(throws: PendingGlancePresentationFenceError.nonCanonical) {
      try codec.decode(undeclared)
    }

    let future = PendingGlancePresentationFenceSnapshot(
      schemaVersion: 2,
      scopes: []
    )
    #expect(throws: PendingGlancePresentationFenceError.invalidSnapshot) {
      try codec.encode(future)
    }
    #expect(
      throws: PendingGlancePresentationFenceError.oversized(
        actualBytes: data.count,
        maximumBytes: 1
      )
    ) {
      try PendingGlancePresentationFenceCodec(
        maximumBytes: 1
      ).decode(data)
    }
  }

  @Test("Eligibility is capped at two minutes and then expires")
  func twoMinuteExpiry() {
    let observedAt = Date(timeIntervalSince1970: 4_000)
    let fact = ExperienceTestFixtures.fact("fact", observedAt: observedAt)
    let event = ExperienceTestFixtures.event(
      "event",
      observedAt: observedAt,
      fact: fact,
      deadline: observedAt.addingTimeInterval(600)
    )
    let policy = PendingGlancePolicy()

    let onBoundary = policy.foregroundActivationPlan(
      events: [event],
      activeProfile: ExperienceTestFixtures.profile(),
      currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
      at: observedAt.addingTimeInterval(120),
      reminderMode: .gentleHaptic,
      quietHours: nonQuietHours,
      timeZone: ExperienceTestFixtures.timeZone
    )
    #expect(onBoundary.presentation?.eventID == event.header.recordID)

    let expired = policy.foregroundActivationPlan(
      events: [event],
      activeProfile: ExperienceTestFixtures.profile(),
      currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
      at: observedAt.addingTimeInterval(121),
      reminderMode: .gentleHaptic,
      quietHours: nonQuietHours,
      timeZone: ExperienceTestFixtures.timeZone
    )
    #expect(expired.presentation == nil)
    #expect(
      expired.terminalDecisions
        == [
          PendingGlanceTerminalDecision(
            eventID: event.header.recordID,
            state: .expired(at: observedAt.addingTimeInterval(121))
          )
        ]
    )
  }

  @Test("Glance, haptic, and quiet hours remain independent controls")
  func preferenceBoundaries() {
    let quietDate = ExperienceTestFixtures.date("2026-07-24T15:00:00Z")
    let fact = ExperienceTestFixtures.fact(
      "quiet-fact",
      observedAt: quietDate.addingTimeInterval(-10)
    )
    let event = ExperienceTestFixtures.event(
      "quiet-event",
      observedAt: fact.observedAt,
      fact: fact
    )
    let policy = PendingGlancePolicy()

    let quiet = policy.foregroundActivationPlan(
      events: [event],
      activeProfile: ExperienceTestFixtures.profile(),
      currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
      at: quietDate,
      reminderMode: .gentleHaptic,
      quietHours: CompanionQuietHours(
        startMinute: 22 * 60 + 30,
        endMinute: 7 * 60
      ),
      timeZone: ExperienceTestFixtures.timeZone
    )
    #expect(quiet.presentation != nil)
    #expect(quiet.presentation?.shouldPlayHaptic == false)

    let noHaptic = policy.foregroundActivationPlan(
      events: [event],
      activeProfile: ExperienceTestFixtures.profile(),
      currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
      at: quietDate,
      reminderMode: .wristRaise,
      quietHours: nonQuietHours,
      timeZone: ExperienceTestFixtures.timeZone
    )
    #expect(noHaptic.presentation != nil)
    #expect(noHaptic.presentation?.shouldPlayHaptic == false)
  }

  @Test("Terminal history never re-enters the pending slot")
  func terminalEventsIgnored() {
    let now = Date(timeIntervalSince1970: 8_000)
    let fact = ExperienceTestFixtures.fact("fact", observedAt: now)
    let event = ExperienceTestFixtures.event(
      "presented",
      observedAt: now,
      fact: fact,
      reminderState: .presented(at: now.addingTimeInterval(1))
    )

    #expect(
      PendingGlancePolicy().foregroundActivationPlan(
        events: [event],
        activeProfile: ExperienceTestFixtures.profile(),
        currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
        at: now.addingTimeInterval(2),
        reminderMode: .gentleHaptic,
        quietHours: nonQuietHours,
        timeZone: ExperienceTestFixtures.timeZone
      ) == .empty
    )
  }

  @Test("A terminal plan assembles into durable domain transitions")
  func transitionAssembly() throws {
    let now = Date(timeIntervalSince1970: 9_000)
    let fact = ExperienceTestFixtures.fact(
      "assembly-fact",
      observedAt: now.addingTimeInterval(-10)
    )
    var event = ExperienceTestFixtures.event(
      "assembly-event",
      observedAt: fact.observedAt,
      fact: fact
    )
    let profile = ExperienceTestFixtures.profile()
    let decision = try #require(
      PendingGlancePolicy().foregroundActivationPlan(
        events: [event],
        activeProfile: profile,
        currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
        at: now,
        reminderMode: .wristRaise,
        quietHours: nonQuietHours,
        timeZone: ExperienceTestFixtures.timeZone
      ).terminalDecisions.first
    )
    let transition = try PendingGlanceTransitionAssembler().assemble(
      decision,
      for: event,
      activeProfile: profile,
      identity: PendingGlanceTransitionIdentity(
        transitionID: EventTransitionID("presented-assembly-event"),
        revision: ExperienceTestFixtures.revision(31, device: "watch")
      )
    )

    #expect(event.apply(transition, in: profile) == .applied)
    #expect(event.reminderState == .presented(at: now))
  }

  @Test("A pending event from another profile fails closed")
  func profileMismatch() {
    let now = Date(timeIntervalSince1970: 10_000)
    let fact = ExperienceTestFixtures.fact("scoped-fact", observedAt: now)
    let event = ExperienceTestFixtures.event(
      "scoped-event",
      observedAt: now,
      fact: fact
    )
    let base = ExperienceTestFixtures.profile()
    let other = RuntimeProfile(
      id: ProfileID("other-profile"),
      epoch: base.epoch,
      deletionEpoch: base.deletionEpoch,
      source: .real
    )

    #expect(
      PendingGlancePolicy().foregroundActivationPlan(
        events: [event],
        activeProfile: other,
        currentSensingEpoch: ExperienceTestFixtures.sensingEpoch(),
        at: now,
        reminderMode: .wristRaise,
        quietHours: nonQuietHours,
        timeZone: ExperienceTestFixtures.timeZone
      ) == .empty
    )
  }
}

private actor ControllablePendingGlanceFenceStorage:
  PendingGlancePresentationFenceStorage
{
  enum TestError: Error {
    case saveFailed
  }

  private var data: Data?
  private var shouldFailNextSave: Bool

  init(shouldFailNextSave: Bool) {
    self.shouldFailNextSave = shouldFailNextSave
  }

  func load() -> Data? {
    data
  }

  func save(_ data: Data) throws {
    if shouldFailNextSave {
      shouldFailNextSave = false
      throw TestError.saveFailed
    }
    self.data = data
  }
}
