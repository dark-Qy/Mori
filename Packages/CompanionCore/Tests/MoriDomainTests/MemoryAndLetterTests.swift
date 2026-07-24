import Foundation
import Testing

@testable import MoriDomain

@Suite("Memories and letters")
struct MemoryAndLetterTests {
  @Test("Daily memory identity is stable and profile, epoch, day, and timezone scoped")
  func stableDailyID() {
    let profile = MoriTestFixtures.profile()
    let day = LocalDay("2026-11-01")
    let first = MemoryID.daily(
      profileID: profile.id,
      profileEpoch: profile.epoch,
      localDay: day,
      timeZoneIdentifier: "America/New_York"
    )
    let repeated = MemoryID.daily(
      profileID: profile.id,
      profileEpoch: profile.epoch,
      localDay: day,
      timeZoneIdentifier: "America/New_York"
    )
    let differentZone = MemoryID.daily(
      profileID: profile.id,
      profileEpoch: profile.epoch,
      localDay: day,
      timeZoneIdentifier: "Asia/Shanghai"
    )
    let nextEpoch = MoriTestFixtures.profile(profileEpoch: 11)
    let differentEpoch = MemoryID.daily(
      profileID: nextEpoch.id,
      profileEpoch: nextEpoch.epoch,
      localDay: day,
      timeZoneIdentifier: "America/New_York"
    )

    #expect(first == repeated)
    #expect(first != differentZone)
    #expect(first != differentEpoch)
    #expect(first.isValid)
  }

  @Test("Calendar-invalid local days are rejected instead of normalized")
  func localDayValidation() {
    #expect(LocalDay("2024-02-29").isValid)
    #expect(LocalDay("2026-02-29").isValid == false)
    #expect(LocalDay("2026-02-30").isValid == false)
    #expect(LocalDay("2026-13-01").isValid == false)
    #expect(LocalDay("2026-7-24").isValid == false)
  }

  @Test("A daily memory seals once and late evidence cannot rewrite it")
  func sealOnce() {
    let profile = MoriTestFixtures.profile()
    var memory = MoriTestFixtures.memory(profile: profile)
    let first = MemoryTransition(
      header: MoriTestFixtures.header(MemoryTransitionID("seal-1"), profile: profile),
      memoryID: memory.header.recordID,
      revision: MoriTestFixtures.revision(71),
      kind: .seal(MoriTestFixtures.memoryContent())
    )
    let late = MemoryTransition(
      header: MoriTestFixtures.header(MemoryTransitionID("seal-2"), profile: profile),
      memoryID: memory.header.recordID,
      revision: MoriTestFixtures.revision(72),
      kind: .seal(MoriTestFixtures.memoryContent(narrative: "迟到的数据改变了故事。"))
    )

    #expect(memory.apply(first, in: profile) == .applied)
    #expect(memory.apply(first, in: profile) == .duplicate)
    #expect(memory.apply(late, in: profile) == .duplicate)
    guard case .sealed(let content) = memory.lifecycle else {
      Issue.record("memory should remain sealed")
      return
    }
    #expect(content.narrative == "今天我们经过了一段很长的路。")
  }

  @Test("Memory deletion is terminal")
  func deletionTerminal() {
    let profile = MoriTestFixtures.profile()
    var memory = MoriTestFixtures.memory(profile: profile)
    let deletion = MemoryTransition(
      header: MoriTestFixtures.header(MemoryTransitionID("delete"), profile: profile),
      memoryID: memory.header.recordID,
      revision: MoriTestFixtures.revision(71),
      kind: .delete(at: MoriTestFixtures.now)
    )
    let seal = MemoryTransition(
      header: MoriTestFixtures.header(MemoryTransitionID("seal"), profile: profile),
      memoryID: memory.header.recordID,
      revision: MoriTestFixtures.revision(72),
      kind: .seal(MoriTestFixtures.memoryContent())
    )

    #expect(memory.apply(deletion, in: profile) == .applied)
    #expect(memory.apply(seal, in: profile) == .duplicate)
    #expect(memory.apply(deletion, in: profile) == .duplicate)
  }

  @Test("Deleted memory lifecycle requires a valid terminal authority")
  func deletedMemoryRequiresTerminalAuthority() {
    let profile = MoriTestFixtures.profile()
    let base = MoriTestFixtures.memory(profile: profile)
    let malformed = MemoryRecord(
      header: base.header,
      localDay: base.localDay,
      timeZoneIdentifier: base.timeZoneIdentifier,
      authoredRevision: base.authoredRevision,
      lifecycle: .deleted(
        at: MoriTestFixtures.now,
        revision: LamportRevision(counter: 0, originDeviceID: "")
      ),
      winningTransitionID: nil
    )

    #expect(malformed.validate(in: profile) == .invalidRecord)

    let baseline = MoriTestFixtures.state(profile: profile)
    let state = ProfileState(
      header: baseline.header,
      runtimeProfile: baseline.runtimeProfile,
      companionSensingEnabled: baseline.companionSensingEnabled,
      currentSensingEpoch: baseline.currentSensingEpoch,
      selectedIdentity: baseline.selectedIdentity,
      identityRevision: baseline.identityRevision,
      tone: baseline.tone,
      coinLedger: baseline.coinLedger,
      collection: baseline.collection,
      memories: [malformed]
    )
    #expect(state.validate() == .invalidRecord)
  }

  @Test("A sealed snapshot cannot preclaim and suppress a deletion transition")
  func sealedSnapshotCannotPreclaimDeletion() {
    let profile = MoriTestFixtures.profile("memory-preclaim")
    let base = MoriTestFixtures.memory(profile: profile)
    let deleteID = MemoryTransitionID("delete-memory")
    let crafted = MemoryRecord(
      header: base.header,
      localDay: base.localDay,
      timeZoneIdentifier: base.timeZoneIdentifier,
      authoredRevision: base.authoredRevision,
      lifecycle: .sealed(MoriTestFixtures.memoryContent()),
      winningTransitionID: deleteID
    )
    let envelope = ExperienceSyncEnvelope(
      eventID: ExperienceEventID("crafted-memory"),
      eventType: .memorySealed,
      profileID: profile.id,
      profileEpoch: profile.epoch,
      deletionEpoch: profile.deletionEpoch,
      profileSource: profile.source,
      originDeviceID: "iphone",
      originSequence: 71,
      revision: MoriTestFixtures.revision(71),
      observedAt: nil,
      authoredAt: MoriTestFixtures.now,
      privacyClass: .referenceOnly,
      tombstone: nil,
      sourceEventID: nil,
      settlementID: nil,
      payload: .memory(crafted)
    )
    #expect(envelope.validate() == .invalidPayload)

    let deletion = MemoryTransition(
      header: MoriTestFixtures.header(deleteID, profile: profile),
      memoryID: crafted.header.recordID,
      revision: MoriTestFixtures.revision(71),
      kind: .delete(at: MoriTestFixtures.now)
    )
    var local = crafted
    #expect(local.apply(deletion, in: profile) == .rejected(.conflictingDuplicate))
    #expect(local.lifecycle.isSealed)
  }

  @Test("Sealed memories and letters require approved local sources")
  func sourceAuthority() {
    let profile = MoriTestFixtures.profile()
    var state = MoriTestFixtures.state(profile: profile)
    var memory = MoriTestFixtures.memory(profile: profile)
    let seal = MemoryTransition(
      header: MoriTestFixtures.header(
        MemoryTransitionID("seal-authorized"),
        profile: profile
      ),
      memoryID: memory.header.recordID,
      revision: MoriTestFixtures.revision(71),
      kind: .seal(MoriTestFixtures.memoryContent())
    )
    #expect(memory.apply(seal, in: profile) == .applied)
    #expect(ProfileReducer.apply(.memory(memory), to: &state) == .rejected(.invalidRecord))

    let fact = MoriTestFixtures.fact(profile: profile)
    #expect(ProfileReducer.apply(.derivedFact(fact), to: &state) == .applied)
    #expect(ProfileReducer.apply(.memory(memory), to: &state) == .applied)

    let letter = MoriTestFixtures.letter(profile: profile)
    #expect(ProfileReducer.apply(.letter(letter), to: &state) == .rejected(.invalidRecord))
    let event = MoriTestFixtures.event(
      profile: profile,
      sensingEpoch: state.currentSensingEpoch,
      fact: fact
    )
    #expect(ProfileReducer.apply(.passiveEvent(event), to: &state) == .applied)
    #expect(ProfileReducer.apply(.letter(letter), to: &state) == .applied)
  }

  @Test("Delete wins over read for every arrival permutation")
  func letterDeleteWins() {
    let profile = MoriTestFixtures.profile()
    let base = MoriTestFixtures.letter(profile: profile)
    let read = MoriTestFixtures.letterTransition(
      "read",
      letter: base,
      profile: profile,
      revision: MoriTestFixtures.revision(62, device: "watch"),
      kind: .read(at: MoriTestFixtures.now)
    )
    let delete = MoriTestFixtures.letterTransition(
      "delete",
      letter: base,
      profile: profile,
      revision: MoriTestFixtures.revision(61, device: "iphone"),
      kind: .delete(at: MoriTestFixtures.now.addingTimeInterval(1))
    )

    var readThenDelete = base
    #expect(readThenDelete.apply(read, in: profile) == .applied)
    #expect(readThenDelete.apply(delete, in: profile) == .applied)

    var deleteThenRead = base
    #expect(deleteThenRead.apply(delete, in: profile) == .applied)
    #expect(deleteThenRead.apply(read, in: profile) == .duplicate)

    #expect(readThenDelete.isDeleted)
    #expect(deleteThenRead.isDeleted)
    #expect(readThenDelete.deletionRevision == deleteThenRead.deletionRevision)
    #expect(readThenDelete.deletionTransitionID == deleteThenRead.deletionTransitionID)
  }

  @Test("Offline letter replicas converge to deleted visibility in either merge direction")
  func letterMergeDeleteWins() {
    let profile = MoriTestFixtures.profile()
    let base = MoriTestFixtures.letter(profile: profile)
    let read = MoriTestFixtures.letterTransition(
      "read",
      letter: base,
      profile: profile,
      revision: MoriTestFixtures.revision(62, device: "watch"),
      kind: .read(at: MoriTestFixtures.now)
    )
    let delete = MoriTestFixtures.letterTransition(
      "delete",
      letter: base,
      profile: profile,
      revision: MoriTestFixtures.revision(61, device: "iphone"),
      kind: .delete(at: MoriTestFixtures.now)
    )
    var readReplica = base
    var deletedReplica = base
    #expect(readReplica.apply(read, in: profile) == .applied)
    #expect(deletedReplica.apply(delete, in: profile) == .applied)

    let lhs = merged(readReplica, with: deletedReplica, profile: profile)
    let rhs = merged(deletedReplica, with: readReplica, profile: profile)
    #expect(lhs?.isDeleted == true)
    #expect(rhs?.isDeleted == true)
  }

  private func merged(
    _ lhs: LetterRecord,
    with rhs: LetterRecord,
    profile: RuntimeProfile
  ) -> LetterRecord? {
    switch lhs.merged(with: rhs, in: profile) {
    case .merged(let record):
      return record
    case .duplicate:
      return lhs
    case .rejected:
      return nil
    }
  }
}
