import Foundation
import MoriDomain
import Testing

@testable import MoriRuntime

@Suite("Lamport profile selection authority")
struct ProfileSelectionAuthorityTests {
  @Test("Mock scenario and selection revision derive a deterministic epoch and profile")
  func deterministicMockDerivation() throws {
    let scenario = MockScenarioID("city-walk")
    let revision = LamportRevision(counter: 42, originDeviceID: "watch")

    let first = try MockProfileDerivation.selection(
      scenarioID: scenario,
      revision: revision
    )
    let second = try MockProfileDerivation.selection(
      scenarioID: scenario,
      revision: revision
    )
    let later = try MockProfileDerivation.selection(
      scenarioID: scenario,
      revision: LamportRevision(counter: 43, originDeviceID: "watch")
    )

    #expect(first == second)
    #expect(first.isValid)
    #expect(first.profile.epoch.revision == revision)
    #expect(first.profile.id == second.profile.id)
    #expect(first.profile.id != later.profile.id)
    #expect(first.profile.epoch != later.profile.epoch)
  }

  @Test("Mock profile hashing frames components that contain delimiters")
  func mockProfileHashingHasNoDelimiterCollision() throws {
    let first = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("a|1"),
      revision: LamportRevision(counter: 2, originDeviceID: "x")
    )
    let second = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("a"),
      revision: LamportRevision(counter: 1, originDeviceID: "2|x")
    )

    #expect(first.profile.id != second.profile.id)
    #expect(first.profile.deletionEpoch.requestID != second.profile.deletionEpoch.requestID)
  }

  @Test("Offline conflicts converge by Lamport order independent of arrival")
  func offlineConflictConvergence() async throws {
    let phoneRevision = LamportRevision(counter: 9, originDeviceID: "phone")
    let watchRevision = LamportRevision(counter: 9, originDeviceID: "watch")
    let phoneSelection = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("phone-choice"),
      revision: phoneRevision
    )
    let watchSelection = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("watch-choice"),
      revision: watchRevision
    )
    #expect(phoneRevision < watchRevision)

    let firstAuthority = try ProfileSelectionAuthority()
    _ = await firstAuthority.merge(phoneSelection)
    #expect(
      await firstAuthority.merge(watchSelection)
        == .applied(watchSelection)
    )

    let secondAuthority = try ProfileSelectionAuthority()
    _ = await secondAuthority.merge(watchSelection)
    #expect(
      await secondAuthority.merge(phoneSelection)
        == .rejected(.losingSelectionRevision)
    )

    #expect(await firstAuthority.current() == watchSelection)
    #expect(await secondAuthority.current() == watchSelection)
  }

  @Test("Equal-revision conflict and losing epochs fail closed")
  func conflictAndLosingEpochRejection() async throws {
    let oldSelection = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("old"),
      revision: LamportRevision(counter: 10, originDeviceID: "watch")
    )
    let winner = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("winner"),
      revision: LamportRevision(counter: 11, originDeviceID: "watch")
    )
    let authority = try ProfileSelectionAuthority(initial: winner)

    #expect(
      await authority.merge(oldSelection)
        == .rejected(.losingSelectionRevision)
    )
    #expect(
      await authority.authorize(oldSelection.profile)
        == .rejected(.supersededProfileEpoch)
    )

    let layout = try RuntimeStorageLayout(
      applicationSupportURL: FileManager.default.temporaryDirectory
    )
    do {
      _ = try await authority.selectedNamespace(
        for: oldSelection.profile,
        in: layout
      )
      Issue.record("Expected losing epoch namespace access to be rejected")
    } catch let rejection as ProfileSelectionRejection {
      #expect(rejection == .supersededProfileEpoch)
    }

    let conflicting = ProfileSelectionRecord(
      profile: RuntimeProfile(
        id: ProfileID("other-valid-profile"),
        epoch: winner.profile.epoch,
        deletionEpoch: winner.profile.deletionEpoch,
        source: winner.profile.source
      ),
      revision: winner.revision
    )
    #expect(conflicting.isValid)
    #expect(
      await authority.merge(conflicting)
        == .rejected(.conflictingRecordAtRevision)
    )
  }

  @Test("Malformed Mock epoch is rejected before it can win")
  func malformedMockEpoch() async throws {
    let profileRevision = LamportRevision(counter: 2, originDeviceID: "watch")
    let sourceRevision = LamportRevision(counter: 3, originDeviceID: "watch")
    let profileEpoch = ProfileEpoch(profileRevision)
    let invalid = ProfileSelectionRecord(
      profile: RuntimeProfile(
        id: ProfileID("invalid-mock"),
        epoch: profileEpoch,
        deletionEpoch: DeletionEpoch(
          requestID: DeletionRequestID("invalid-mock"),
          revision: profileRevision
        ),
        source: .mock(
          scenarioID: MockScenarioID("scenario"),
          selectionEpoch: ProfileEpoch(sourceRevision)
        )
      ),
      revision: profileRevision
    )
    let authority = try ProfileSelectionAuthority()

    #expect(invalid.isValid == false)
    #expect(
      await authority.merge(invalid)
        == .rejected(.invalidRecord)
    )
    #expect(await authority.current() == nil)
  }
}
