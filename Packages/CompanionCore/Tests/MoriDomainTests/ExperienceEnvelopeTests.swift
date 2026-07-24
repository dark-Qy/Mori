import Foundation
import Testing

@testable import MoriDomain

@Suite("Experience sync envelope")
struct ExperienceEnvelopeTests {
  @Test("Approved product state validates and survives a codec restart")
  func validRoundTrip() throws {
    let envelope = MoriTestFixtures.identitySelectionEnvelope()
    #expect(envelope.validate() == nil)

    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(ExperienceSyncEnvelope.self, from: data)
    #expect(decoded == envelope)
    #expect(decoded.validate() == nil)
  }

  @Test("Schema, event type, privacy, and profile are fail-closed")
  func negativeMetadata() {
    let profile = MoriTestFixtures.profile()
    let payload = identityPayload(profile: profile)

    #expect(
      envelope(profile: profile, payload: payload, schemaVersion: 2).validate() == .invalidSchema)
    #expect(
      envelope(profile: profile, payload: payload, eventType: .coinEarned).validate()
        == .invalidPayload
    )
    #expect(
      envelope(profile: profile, payload: payload, privacyClass: .approvedDerived).validate()
        == .invalidPayload
    )

    let foreign = MoriTestFixtures.profile("foreign")
    #expect(
      envelope(
        profile: foreign,
        payload: payload,
        eventID: ExperienceEventID("foreign-envelope")
      ).validate() == .profileMismatch
    )
  }

  @Test("Tombstones are forbidden for live payloads")
  func livePayloadCannotCarryTombstone() {
    let profile = MoriTestFixtures.profile()
    let payload = identityPayload(profile: profile)
    let tombstone = ExperienceTombstone(
      targetRecordID: payload.aggregateRecordID,
      reason: .userDeleted
    )
    #expect(
      envelope(profile: profile, payload: payload, tombstone: tombstone).validate()
        == .tombstoneMismatch
    )
  }

  @Test("Deletion payload requires a tombstone for the exact aggregate")
  func deletionTombstone() {
    let profile = MoriTestFixtures.profile()
    let memory = MoriTestFixtures.memory(profile: profile)
    let transition = MemoryTransition(
      header: MoriTestFixtures.header(MemoryTransitionID("delete-memory"), profile: profile),
      memoryID: memory.header.recordID,
      revision: MoriTestFixtures.revision(91),
      kind: .delete(at: MoriTestFixtures.now)
    )
    let payload = ExperienceSyncPayload.memoryTransition(transition)
    let without = envelope(
      profile: profile,
      payload: payload,
      eventType: .memoryDeleted,
      privacyClass: .referenceOnly
    )
    #expect(without.validate() == .tombstoneMismatch)

    let wrong = envelope(
      profile: profile,
      payload: payload,
      eventType: .memoryDeleted,
      privacyClass: .referenceOnly,
      tombstone: ExperienceTombstone(
        targetRecordID: "some-other-memory",
        reason: .userDeleted
      )
    )
    #expect(wrong.validate() == .tombstoneMismatch)

    let valid = envelope(
      profile: profile,
      payload: payload,
      eventType: .memoryDeleted,
      privacyClass: .referenceOnly,
      tombstone: ExperienceTombstone(
        targetRecordID: memory.header.recordID.rawValue,
        reason: .userDeleted
      )
    )
    #expect(valid.validate() == nil)
  }

  private func identityPayload(profile: RuntimeProfile) -> ExperienceSyncPayload {
    .identitySelection(
      IdentitySelectionRecord(
        header: MoriTestFixtures.header(
          IdentitySelectionID("selection"),
          profile: profile
        ),
        identity: .polarBear,
        revision: MoriTestFixtures.revision(90)
      )
    )
  }

  private func envelope(
    profile: RuntimeProfile,
    payload: ExperienceSyncPayload,
    schemaVersion: UInt16 = 1,
    eventID: ExperienceEventID = ExperienceEventID("experience"),
    eventType: ExperienceEventType? = nil,
    privacyClass: ExperiencePrivacyClass? = nil,
    tombstone: ExperienceTombstone? = nil
  ) -> ExperienceSyncEnvelope {
    ExperienceSyncEnvelope(
      schemaVersion: schemaVersion,
      eventID: eventID,
      eventType: eventType ?? payload.eventType,
      profileID: profile.id,
      profileEpoch: profile.epoch,
      deletionEpoch: profile.deletionEpoch,
      originDeviceID: "iphone",
      originSequence: 1,
      revision: MoriTestFixtures.revision(90),
      observedAt: nil,
      authoredAt: MoriTestFixtures.now,
      privacyClass: privacyClass ?? payload.expectedPrivacyClass,
      tombstone: tombstone,
      sourceEventID: nil,
      settlementID: nil,
      payload: payload
    )
  }
}
