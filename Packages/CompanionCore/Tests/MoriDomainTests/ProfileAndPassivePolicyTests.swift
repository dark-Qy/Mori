import Foundation
import Testing

@testable import MoriDomain

@Suite("Profile scope and passive evidence policy")
struct ProfileAndPassivePolicyTests {
  @Test("Lamport order is logical and deterministic when counters tie")
  func lamportOrder() {
    let earlier = MoriTestFixtures.revision(7, device: "a-watch")
    let later = MoriTestFixtures.revision(7, device: "b-phone")

    #expect(earlier < later)
    #expect(MoriTestFixtures.revision(6, device: "z") < earlier)
    #expect(earlier.isValid)
    #expect(LamportRevision(counter: 1, originDeviceID: " \n").isValid == false)
  }

  @Test("Mock profile epoch must equal its selection epoch")
  func mockSelectionEpoch() {
    let valid = MoriTestFixtures.mockProfile()
    #expect(valid.isValid)
    #expect(valid.isMock)

    let invalid = RuntimeProfile(
      id: valid.id,
      epoch: valid.epoch,
      deletionEpoch: valid.deletionEpoch,
      source: .mock(
        scenarioID: MockScenarioID("ordinary-day"),
        selectionEpoch: ProfileEpoch(MoriTestFixtures.revision(11, device: "profile-authority"))
      )
    )
    #expect(invalid.isValid == false)
  }

  @Test("Headers reject profile, profile epoch, and deletion epoch crossovers")
  func completeScope() {
    let current = MoriTestFixtures.profile()
    let header = MoriTestFixtures.header(EventID("event"), profile: current)

    #expect(header.scopeMatches(current))
    #expect(header.scopeMatches(MoriTestFixtures.profile("other")) == false)
    #expect(
      header.scopeMatches(
        MoriTestFixtures.profile(profileEpoch: current.epoch.revision.counter + 1)
      ) == false
    )
    #expect(
      header.scopeMatches(
        MoriTestFixtures.profile(deletionEpoch: current.deletionEpoch.revision.counter + 1)
      ) == false
    )
  }

  @Test("Event validation distinguishes profile, profile epoch, and deletion fences")
  func preciseFenceRejections() {
    let current = MoriTestFixtures.profile()
    let sensingEpoch = SensingEpoch(MoriTestFixtures.revision(30, device: "watch"))

    let foreign = MoriTestFixtures.profile("other")
    #expect(
      MoriTestFixtures.event(
        "foreign",
        profile: foreign,
        sensingEpoch: sensingEpoch
      ).validate(in: current, sensingEpoch: sensingEpoch) == .profileMismatch
    )

    let staleProfileEpoch = MoriTestFixtures.profile(profileEpoch: 9)
    #expect(
      MoriTestFixtures.event(
        "stale-profile",
        profile: staleProfileEpoch,
        sensingEpoch: sensingEpoch
      ).validate(in: current, sensingEpoch: sensingEpoch) == .profileEpochMismatch
    )

    let staleDeletionEpoch = MoriTestFixtures.profile(deletionEpoch: 19)
    #expect(
      MoriTestFixtures.event(
        "stale-deletion",
        profile: staleDeletionEpoch,
        sensingEpoch: sensingEpoch
      ).validate(in: current, sensingEpoch: sensingEpoch) == .deletionEpochMismatch
    )
  }

  @Test("Deletion fences retain request identity across retries")
  func deletionFenceIdentity() {
    let first = DeletionEpoch(
      requestID: DeletionRequestID("delete-request-a"),
      revision: MoriTestFixtures.revision(9, device: "authority")
    )
    let retry = DeletionEpoch(
      requestID: DeletionRequestID("delete-request-a"),
      revision: MoriTestFixtures.revision(9, device: "authority")
    )
    let separateRequest = DeletionEpoch(
      requestID: DeletionRequestID("delete-request-b"),
      revision: MoriTestFixtures.revision(9, device: "authority")
    )

    #expect(first == retry)
    #expect(first != separateRequest)
    #expect(first < separateRequest)
  }

  @Test("Low confidence remains silent while medium is the visible boundary")
  func confidenceBoundary() {
    let profile = MoriTestFixtures.profile()
    let sensingEpoch = SensingEpoch(MoriTestFixtures.revision(30, device: "watch"))
    let low = MoriTestFixtures.event(
      "low",
      profile: profile,
      sensingEpoch: sensingEpoch,
      confidence: .low
    )
    let medium = MoriTestFixtures.event(
      "medium",
      profile: profile,
      sensingEpoch: sensingEpoch,
      confidence: .medium
    )

    #expect(low.permitsVisibleClaim == false)
    #expect(low.validate(in: profile, sensingEpoch: sensingEpoch) == .lowConfidence)
    #expect(medium.permitsVisibleClaim)
    #expect(medium.validate(in: profile, sensingEpoch: sensingEpoch) == nil)
  }

  @Test("A passive event requires current sensing epoch and matching evidence")
  func sensingAndEvidence() {
    let profile = MoriTestFixtures.profile()
    var state = MoriTestFixtures.state(profile: profile)
    let fact = MoriTestFixtures.fact(profile: profile)
    let event = MoriTestFixtures.event(
      profile: profile,
      sensingEpoch: state.currentSensingEpoch,
      fact: fact
    )

    #expect(ProfileReducer.apply(.passiveEvent(event), to: &state) == .rejected(.invalidRecord))
    #expect(ProfileReducer.apply(.derivedFact(fact), to: &state) == .applied)
    #expect(ProfileReducer.apply(.passiveEvent(event), to: &state) == .applied)
    #expect(ProfileReducer.apply(.passiveEvent(event), to: &state) == .duplicate)

    let oldEpochEvent = MoriTestFixtures.event(
      "stale-epoch",
      profile: profile,
      sensingEpoch: SensingEpoch(MoriTestFixtures.revision(29, device: "watch")),
      fact: fact
    )
    #expect(
      ProfileReducer.apply(.passiveEvent(oldEpochEvent), to: &state)
        == .rejected(.sensingEpochMismatch)
    )

    let staleFact = MoriTestFixtures.fact(
      "stale-fact",
      profile: profile,
      observedAt: MoriTestFixtures.now.addingTimeInterval(-7_200),
      freshUntil: MoriTestFixtures.now.addingTimeInterval(-3_600)
    )
    let staleClaim = MoriTestFixtures.event(
      "stale-claim",
      profile: profile,
      sensingEpoch: state.currentSensingEpoch,
      fact: staleFact,
      observedAt: MoriTestFixtures.now
    )
    #expect(ProfileReducer.apply(.derivedFact(staleFact), to: &state) == .applied)
    #expect(
      ProfileReducer.apply(.passiveEvent(staleClaim), to: &state)
        == .rejected(.invalidRecord)
    )
  }

  @Test("Disabling sensing advances authority and expires old pending glance")
  func disablingSensingExpiresGlance() {
    let profile = MoriTestFixtures.profile()
    var state = MoriTestFixtures.state(profile: profile)
    let fact = MoriTestFixtures.fact(profile: profile)
    let event = MoriTestFixtures.event(
      profile: profile,
      sensingEpoch: state.currentSensingEpoch,
      fact: fact
    )
    #expect(ProfileReducer.apply(.derivedFact(fact), to: &state) == .applied)
    #expect(ProfileReducer.apply(.passiveEvent(event), to: &state) == .applied)

    let nextEpoch = SensingEpoch(MoriTestFixtures.revision(31, device: "watch"))
    #expect(
      state.setCompanionSensing(enabled: false, epoch: nextEpoch, effectiveAt: .now)
        == .applied
    )
    #expect(state.companionSensingEnabled == false)
    #expect(state.currentSensingEpoch == nextEpoch)
    #expect(state.passiveEvents.first?.reminderState.isTerminal == true)

    let nextFact = MoriTestFixtures.fact("next", profile: profile)
    let nextEvent = MoriTestFixtures.event(
      "next",
      profile: profile,
      sensingEpoch: nextEpoch,
      fact: nextFact
    )
    #expect(
      ProfileReducer.apply(.derivedFact(nextFact), to: &state)
        == .rejected(.sensingEpochMismatch)
    )
    let displayOnly = MoriTestFixtures.fact(
      "display-only",
      profile: profile,
      authorization: .displayOnly
    )
    #expect(ProfileReducer.apply(.derivedFact(displayOnly), to: &state) == .applied)
    #expect(
      ProfileReducer.apply(.passiveEvent(nextEvent), to: &state)
        == .rejected(.sensingEpochMismatch)
    )

    let reenabledEpoch = SensingEpoch(MoriTestFixtures.revision(32, device: "watch"))
    #expect(
      state.setCompanionSensing(
        enabled: true,
        epoch: reenabledEpoch,
        effectiveAt: .now
      ) == .applied
    )
    let backfill = MoriTestFixtures.event(
      "disabled-interval-backfill",
      profile: profile,
      sensingEpoch: reenabledEpoch,
      fact: displayOnly
    )
    #expect(
      ProfileReducer.apply(.passiveEvent(backfill), to: &state)
        == .rejected(.invalidRecord)
    )

    let currentFact = MoriTestFixtures.fact(
      "current",
      profile: profile,
      authorization: .companion(reenabledEpoch)
    )
    let currentEvent = MoriTestFixtures.event(
      "current",
      profile: profile,
      sensingEpoch: reenabledEpoch,
      fact: currentFact
    )
    #expect(ProfileReducer.apply(.derivedFact(currentFact), to: &state) == .applied)
    #expect(ProfileReducer.apply(.passiveEvent(currentEvent), to: &state) == .applied)
  }
}
