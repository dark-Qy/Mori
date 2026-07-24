import Foundation
import Testing

@testable import MoriDomain

@Suite("Derived fact admission regressions")
struct DerivedFactAdmissionRegressionTests {
  @Test("Reducer rejects unsupported derived-fact schemas without mutating valid state")
  func rejectsUnsupportedSchema() {
    let profile = MoriTestFixtures.profile()
    var state = MoriTestFixtures.state(profile: profile)
    let baseline = state
    let fact = DerivedFactRecord(
      header: MoriTestFixtures.header(
        EvidenceID("future-steps"),
        profile: profile,
        schemaVersion: 99
      ),
      observedAt: MoriTestFixtures.now,
      freshUntil: MoriTestFixtures.now.addingTimeInterval(3_600),
      value: .stepTotal(3_250),
      provenance: .deterministicMock
    )

    let result = ProfileReducer.apply(.derivedFact(fact), to: &state)

    #expect(result.isRejected)
    #expect(state == baseline)
    #expect(state.validate() == nil)
  }

  @Test("Reducer rejects negative step totals without mutating valid state")
  func rejectsNegativeSteps() {
    let profile = MoriTestFixtures.profile()
    var state = MoriTestFixtures.state(profile: profile)
    let baseline = state
    let fact = MoriTestFixtures.fact(
      "negative-steps",
      profile: profile,
      value: .stepTotal(-1)
    )

    let result = ProfileReducer.apply(.derivedFact(fact), to: &state)

    #expect(result.isRejected)
    #expect(state == baseline)
    #expect(state.validate() == nil)
  }

  @Test("Facts cannot authorize claims before they were observed")
  func rejectsUseBeforeObservation() {
    let profile = MoriTestFixtures.profile()
    var state = MoriTestFixtures.state(profile: profile)
    let futureFact = MoriTestFixtures.fact(
      "future-fact",
      profile: profile,
      observedAt: MoriTestFixtures.now.addingTimeInterval(60)
    )
    let event = MoriTestFixtures.event(
      "premature-event",
      profile: profile,
      sensingEpoch: state.currentSensingEpoch,
      fact: futureFact,
      observedAt: MoriTestFixtures.now
    )

    #expect(ProfileReducer.apply(.derivedFact(futureFact), to: &state) == .applied)
    #expect(
      ProfileReducer.apply(.passiveEvent(event), to: &state)
        == .rejected(.invalidRecord)
    )
  }

  @Test("Real and Mock fact provenance cannot cross profile authority")
  func rejectsCrossProfileProvenance() {
    let real = MoriTestFixtures.profile("real-provenance")
    let mock = MoriTestFixtures.mockProfile("mock-provenance")
    let realMockFact = MoriTestFixtures.fact(
      "mock-in-real",
      profile: real,
      provenance: .deterministicMock
    )
    let mockRealFact = MoriTestFixtures.fact(
      "real-in-mock",
      profile: mock,
      provenance: .healthSummary
    )
    let validMockFact = MoriTestFixtures.fact(
      "mock-in-mock",
      profile: mock,
      provenance: .deterministicMock
    )

    #expect(realMockFact.validate(in: real) == .profileMismatch)
    #expect(mockRealFact.validate(in: mock) == .profileMismatch)
    #expect(validMockFact.validate(in: mock) == nil)

    let envelope = ExperienceSyncEnvelope(
      eventID: ExperienceEventID("mock-fact-in-real-envelope"),
      eventType: .derivedFact,
      profileID: real.id,
      profileEpoch: real.epoch,
      deletionEpoch: real.deletionEpoch,
      profileSource: .real,
      originDeviceID: "iphone",
      originSequence: 1,
      revision: MoriTestFixtures.revision(100),
      observedAt: realMockFact.observedAt,
      authoredAt: MoriTestFixtures.now,
      privacyClass: .approvedDerived,
      tombstone: nil,
      sourceEventID: nil,
      settlementID: nil,
      payload: .derivedFact(realMockFact)
    )
    #expect(envelope.validate() == .profileMismatch)
  }

  @Test("Every real fact kind is bound to its sole approved provenance")
  func closesRealValueProvenancePairs() {
    let real = MoriTestFixtures.profile("provenance-pairs")
    let validPairs: [(DerivedFactValue, EvidenceProvenance)] = [
      (.stepTotal(3_250), .healthSummary),
      (.sleepDuration(27_000), .healthSummary),
      (.broadMotion(.walking), .motionClassifier),
      (.approvedPlaceCategory(.park), .coarsePlaceClassifier),
      (.foregroundInteraction, .foregroundInteraction),
    ]

    for (index, pair) in validPairs.enumerated() {
      let fact = MoriTestFixtures.fact(
        "valid-pair-\(index)",
        profile: real,
        value: pair.0,
        provenance: pair.1
      )
      #expect(fact.validate(in: real) == nil)
    }

    let mismatched = MoriTestFixtures.fact(
      "steps-from-motion",
      profile: real,
      value: .stepTotal(3_250),
      provenance: .motionClassifier
    )
    #expect(mismatched.validate(in: real) == .invalidRecord)
  }
}

extension MutationResult {
  fileprivate var isRejected: Bool {
    if case .rejected = self { return true }
    return false
  }
}
