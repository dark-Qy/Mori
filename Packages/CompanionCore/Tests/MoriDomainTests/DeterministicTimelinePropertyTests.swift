import Foundation
import Testing

@testable import MoriDomain

@Suite("Deterministic Mori timeline properties")
struct DeterministicTimelinePropertyTests {
  @Test(
    "Duplicate, reorder, restart, isolation, rollback, DST, task, letter, and coin invariants",
    arguments: 0..<1_000
  )
  func timeline(seed: Int) throws {
    var generator = DeterministicGenerator(seed: seed)
    let profile = MoriTestFixtures.profile("seed-\(seed)")
    var state = MoriTestFixtures.state(profile: profile)

    // Duplicate evidence/event replay is idempotent.
    let fact = MoriTestFixtures.fact("steps-\(seed)", profile: profile)
    let event = MoriTestFixtures.event(
      "event-\(seed)",
      profile: profile,
      sensingEpoch: state.currentSensingEpoch,
      fact: fact,
      confidence: .high,
      cooldownKey: TaskCooldownKey("walk")
    )
    #expect(ProfileReducer.apply(.derivedFact(fact), to: &state) == .applied)
    #expect(ProfileReducer.apply(.derivedFact(fact), to: &state) == .duplicate)
    #expect(ProfileReducer.apply(.passiveEvent(event), to: &state) == .applied)
    #expect(ProfileReducer.apply(.passiveEvent(event), to: &state) == .duplicate)

    // Reliable automatic tasks allow either race participant, while uncertain
    // user-confirmation tasks reject an invented automatic completion.
    let isAutomatic = generator.next().isMultiple(of: 2)
    let policy: TaskCompletionPolicy = isAutomatic ? .automatic : .userConfirmation
    let acceptedMethod: TaskCompletionMethod = isAutomatic ? .automatic : .userConfirmed
    let rejectedMethod: TaskCompletionMethod = isAutomatic ? .userConfirmed : .automatic
    let task = MoriTestFixtures.task(
      "task-\(seed)",
      event: event,
      profile: profile,
      issuedRevision: MoriTestFixtures.revision(50, device: "seed-\(seed)"),
      policy: policy,
      reward: .smallest
    )
    #expect(
      ProfileReducer.apply(.task(task, manualTaskHasVisibleSlot: true), to: &state) == .applied)
    let rejectedCompletion = MoriTestFixtures.taskTransition(
      "rejected-\(seed)",
      task: task,
      profile: profile,
      revision: MoriTestFixtures.revision(52, device: "contender"),
      method: rejectedMethod
    )
    if isAutomatic {
      #expect(ProfileReducer.apply(.taskTransition(rejectedCompletion), to: &state) == .applied)
    } else {
      #expect(
        ProfileReducer.apply(.taskTransition(rejectedCompletion), to: &state)
          == .rejected(.completionNotAllowed)
      )
    }
    let acceptedCompletion = MoriTestFixtures.taskTransition(
      "accepted-\(seed)",
      task: task,
      profile: profile,
      revision: MoriTestFixtures.revision(51, device: "authority"),
      method: acceptedMethod
    )
    #expect(ProfileReducer.apply(.taskTransition(acceptedCompletion), to: &state) == .applied)
    #expect(ProfileReducer.apply(.taskTransition(acceptedCompletion), to: &state) == .duplicate)

    let reward = MoriTestFixtures.reward(
      "reward-\(seed)",
      settlementID: task.settlementID,
      profile: profile,
      revision: MoriTestFixtures.revision(53),
      tier: .smallest
    )
    #expect(ProfileReducer.apply(.coinTransaction(reward), to: &state) == .applied)
    #expect(ProfileReducer.apply(.coinTransaction(reward), to: &state) == .duplicate)
    #expect(state.coinLedger.balance == 1)

    // A rollback never bypasses the task cooldown, while its exact boundary does.
    let nextFact = MoriTestFixtures.fact("steps-next-\(seed)", profile: profile)
    let nextEvent = MoriTestFixtures.event(
      "event-next-\(seed)",
      profile: profile,
      sensingEpoch: state.currentSensingEpoch,
      fact: nextFact,
      observedAt: MoriTestFixtures.now.addingTimeInterval(1),
      cooldownKey: TaskCooldownKey("walk")
    )
    #expect(ProfileReducer.apply(.derivedFact(nextFact), to: &state) == .applied)
    #expect(ProfileReducer.apply(.passiveEvent(nextEvent), to: &state) == .applied)
    let rollback = MoriTestFixtures.task(
      "rollback-\(seed)",
      event: nextEvent,
      profile: profile,
      issuedAt: MoriTestFixtures.now.addingTimeInterval(-Double(generator.next() % 10_000 + 1)),
      issuedRevision: MoriTestFixtures.revision(54),
      policy: .userConfirmation
    )
    #expect(
      ProfileReducer.apply(.task(rollback, manualTaskHasVisibleSlot: true), to: &state)
        == .rejected(.cooldownActive)
    )
    let boundary = MoriTestFixtures.task(
      "boundary-\(seed)",
      event: nextEvent,
      profile: profile,
      issuedAt: MoriTestFixtures.now.addingTimeInterval(900),
      issuedRevision: MoriTestFixtures.revision(55),
      policy: .userConfirmation
    )
    #expect(
      ProfileReducer.apply(.task(boundary, manualTaskHasVisibleSlot: true), to: &state) == .applied
    )

    // Crossing local midnight or a DST gap cannot shorten an absolute cooldown.
    var shanghai = Calendar(identifier: .gregorian)
    shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let beforeMidnight = try #require(
      shanghai.date(
        from: DateComponents(year: 2026, month: 7, day: 24, hour: 23, minute: 59)
      )
    )
    let afterMidnight = beforeMidnight.addingTimeInterval(120)
    #expect(
      shanghai.component(.day, from: beforeMidnight)
        != shanghai.component(.day, from: afterMidnight)
    )
    let midnightCooldown = TaskCooldownRecord(
      header: MoriTestFixtures.header(
        TaskCooldownID("midnight-\(seed)"),
        profile: profile
      ),
      key: TaskCooldownKey("midnight"),
      issuedAt: beforeMidnight,
      duration: 900,
      revision: MoriTestFixtures.revision(56)
    )
    #expect(midnightCooldown.permits(issuanceAt: afterMidnight) == false)

    var newYork = Calendar(identifier: .gregorian)
    newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let beforeDSTGap = try #require(
      newYork.date(
        from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30)
      )
    )
    let afterDSTGap = beforeDSTGap.addingTimeInterval(3_600)
    #expect(newYork.component(.hour, from: afterDSTGap) == 3)
    #expect(
      TaskCooldownRecord(
        header: MoriTestFixtures.header(
          TaskCooldownID("dst-\(seed)"),
          profile: profile
        ),
        key: TaskCooldownKey("dst"),
        issuedAt: beforeDSTGap,
        duration: 7_200,
        revision: MoriTestFixtures.revision(57)
      ).permits(issuanceAt: afterDSTGap) == false
    )

    // Late evidence remains valid only for the instant it actually supports.
    let lateObservedAt = MoriTestFixtures.now.addingTimeInterval(-86_400)
    let lateFact = MoriTestFixtures.fact(
      "late-fact-\(seed)",
      profile: profile,
      observedAt: lateObservedAt,
      freshUntil: lateObservedAt.addingTimeInterval(3_600)
    )
    let lateEvent = MoriTestFixtures.event(
      "late-event-\(seed)",
      profile: profile,
      sensingEpoch: state.currentSensingEpoch,
      fact: lateFact,
      observedAt: lateObservedAt.addingTimeInterval(600),
      cooldownKey: nil
    )
    #expect(ProfileReducer.apply(.derivedFact(lateFact), to: &state) == .applied)
    #expect(ProfileReducer.apply(.passiveEvent(lateEvent), to: &state) == .applied)

    // Expiry remains authoritative for a completion that genuinely occurred
    // too late. The valid terminal loser is consumed as a no-op.
    let expiry = TaskTransition(
      header: MoriTestFixtures.header(
        TaskTransitionID("expiry-\(seed)"),
        profile: profile
      ),
      taskID: boundary.header.recordID,
      revision: MoriTestFixtures.revision(58),
      state: .expired(at: try #require(boundary.expiresAt)),
      settlementID: nil
    )
    #expect(ProfileReducer.apply(.taskTransition(expiry), to: &state) == .applied)
    let lateCompletion = TaskTransition(
      header: MoriTestFixtures.header(
        TaskTransitionID("late-completion-\(seed)"),
        profile: profile
      ),
      taskID: boundary.header.recordID,
      revision: MoriTestFixtures.revision(59),
      state: .completed(
        method: .userConfirmed,
        at: try #require(boundary.expiresAt).addingTimeInterval(1)
      ),
      settlementID: boundary.settlementID
    )
    #expect(
      ProfileReducer.apply(.taskTransition(lateCompletion), to: &state)
        == .duplicate
    )

    // Independent coin records converge under opposite arrival orders.
    let independent = (0..<8).map { index in
      MoriTestFixtures.reward(
        "independent-\(seed)-\(index)",
        settlementID: TaskSettlementID("independent-settlement-\(seed)-\(index)"),
        profile: profile,
        revision: MoriTestFixtures.revision(
          UInt64(100 + index % 3),
          device: index.isMultiple(of: 2) ? "watch" : "iphone"
        ),
        tier: CoinRewardTier.allCases[(seed + index) % CoinRewardTier.allCases.count]
      )
    }
    var forward = CoinLedger(
      header: MoriTestFixtures.header(CoinLedgerID("property-coins"), profile: profile)
    )
    var reversed = forward
    for transaction in independent {
      #expect(forward.apply(transaction, in: profile) == .applied)
    }
    for transaction in independent.reversed() {
      #expect(reversed.apply(transaction, in: profile) == .applied)
    }
    #expect(forward == reversed)

    // Delete visibility wins for offline letter transition permutations.
    let letter = MoriTestFixtures.letter("letter-\(seed)", profile: profile)
    let read = MoriTestFixtures.letterTransition(
      "read-\(seed)",
      letter: letter,
      profile: profile,
      revision: MoriTestFixtures.revision(201, device: "watch"),
      kind: .read(at: MoriTestFixtures.now)
    )
    let delete = MoriTestFixtures.letterTransition(
      "delete-\(seed)",
      letter: letter,
      profile: profile,
      revision: MoriTestFixtures.revision(200, device: "iphone"),
      kind: .delete(at: MoriTestFixtures.now)
    )
    var readFirst = letter
    var deleteFirst = letter
    #expect(readFirst.apply(read, in: profile) == .applied)
    #expect(readFirst.apply(delete, in: profile) == .applied)
    #expect(deleteFirst.apply(delete, in: profile) == .applied)
    #expect(deleteFirst.apply(read, in: profile) == .duplicate)
    #expect(readFirst.isDeleted && deleteFirst.isDeleted)
    #expect(readFirst.deletionRevision == deleteFirst.deletionRevision)

    // Local-day identity is stable through both DST transition days and zones.
    let zones = ["America/New_York", "Europe/Berlin", "Asia/Shanghai"]
    let days = ["2026-03-08", "2026-10-25", "2026-11-01"]
    let zone = zones[Int(generator.next() % UInt64(zones.count))]
    let day = LocalDay(days[Int(generator.next() % UInt64(days.count))])
    let memoryID = MemoryID.daily(
      profileID: profile.id,
      profileEpoch: profile.epoch,
      localDay: day,
      timeZoneIdentifier: zone
    )
    #expect(
      memoryID
        == MemoryID.daily(
          profileID: profile.id,
          profileEpoch: profile.epoch,
          localDay: day,
          timeZoneIdentifier: zone
        )
    )

    // Codec restart preserves the exact profile-scoped logical state.
    let encoded = try JSONEncoder().encode(state)
    var restarted = try JSONDecoder().decode(ProfileState.self, from: encoded)
    #expect(restarted == state)
    #expect(restarted.validate() == nil)

    // Neither a foreign profile nor a stale profile epoch can mutate it.
    let foreign = MoriTestFixtures.profile("foreign-\(seed)")
    let foreignFact = MoriTestFixtures.fact("foreign-\(seed)", profile: foreign)
    #expect(
      ProfileReducer.apply(.derivedFact(foreignFact), to: &restarted)
        == .rejected(.profileMismatch)
    )
    let staleProfile = MoriTestFixtures.profile(
      "seed-\(seed)",
      profileEpoch: profile.epoch.revision.counter + 1
    )
    let staleFact = MoriTestFixtures.fact("stale-\(seed)", profile: staleProfile)
    #expect(
      ProfileReducer.apply(.derivedFact(staleFact), to: &restarted)
        == .rejected(.profileEpochMismatch)
    )
    #expect(restarted == state)
  }
}
