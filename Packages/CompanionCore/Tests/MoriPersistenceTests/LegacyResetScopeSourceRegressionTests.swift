import Foundation
import MoriDomain
import MoriPersistence
import Testing

@Suite("Legacy reset scope and profile-source regression")
struct LegacyResetScopeSourceRegressionTests {
  @Test("A mock scope cannot reset or purge a real profile source")
  func mockScopeCannotPurgeRealSource() async throws {
    let source = InMemoryLegacyResetSourceStorage(
      snapshot: LegacyResetSourceSnapshot(
        progressionData: Data("real-legacy-progression".utf8),
        preferencesData: nil
      )
    )
    let destination = InMemoryLegacyResetBundleStorage()
    let coordinator = LegacyResetCoordinator(source: source, destination: destination)

    await #expect(throws: LegacyResetCoordinatorError.bundleProfileMismatch) {
      _ = try await coordinator.run(
        scope: try LegacyStoreScope(kind: .mock, storeKey: "mock-ordinary-day"),
        initialState: resetState(source: .real)
      )
    }

    #expect(await source.purgeCount == 0)
    #expect(await source.loadSnapshot().progressionData != nil)
    #expect(await destination.load() == nil)
  }

  @Test("A real scope cannot reset or purge a mock profile source")
  func realScopeCannotPurgeMockSource() async throws {
    let source = InMemoryLegacyResetSourceStorage(
      snapshot: LegacyResetSourceSnapshot(
        progressionData: Data("mock-legacy-progression".utf8),
        preferencesData: nil
      )
    )
    let destination = InMemoryLegacyResetBundleStorage()
    let coordinator = LegacyResetCoordinator(source: source, destination: destination)
    let epoch = ProfileEpoch(resetRevision(1))

    await #expect(throws: LegacyResetCoordinatorError.bundleProfileMismatch) {
      _ = try await coordinator.run(
        scope: try LegacyStoreScope(kind: .real, storeKey: "real"),
        initialState: resetState(
          source: .mock(
            scenarioID: MockScenarioID("ordinary-day"),
            selectionEpoch: epoch
          ),
          epoch: epoch
        )
      )
    }

    #expect(await source.purgeCount == 0)
    #expect(await source.loadSnapshot().progressionData != nil)
    #expect(await destination.load() == nil)
  }
}

private func resetState(
  source: RuntimeProfileSource,
  epoch: ProfileEpoch = ProfileEpoch(resetRevision(1))
) -> ProfileState {
  let profileID: ProfileID
  switch source {
  case .real:
    profileID = ProfileID("real")
  case .mock(let scenarioID, _):
    profileID = ProfileID("mock-\(scenarioID.rawValue)")
  }
  let profile = RuntimeProfile(
    id: profileID,
    epoch: epoch,
    deletionEpoch: DeletionEpoch(
      requestID: DeletionRequestID("initial-delete-fence"),
      revision: resetRevision(1)
    ),
    source: source
  )
  return ProfileState(
    header: resetHeader(profile.id, profile: profile),
    runtimeProfile: profile,
    companionSensingEnabled: true,
    currentSensingEpoch: SensingEpoch(resetRevision(1)),
    selectedIdentity: .penguin,
    identityRevision: resetRevision(1),
    coinLedger: CoinLedger(
      header: resetHeader(CoinLedgerID("coins"), profile: profile)
    ),
    collection: CollectionState(
      header: resetHeader(CollectionID("collection"), profile: profile)
    )
  )
}

private func resetRevision(_ counter: UInt64) -> LamportRevision {
  LamportRevision(counter: counter, originDeviceID: "regression-test")
}

private func resetHeader<RecordID: Hashable & Codable & Sendable>(
  _ recordID: RecordID,
  profile: RuntimeProfile
) -> ProfileScopedRecordHeader<RecordID> {
  ProfileScopedRecordHeader(
    recordID: recordID,
    profileID: profile.id,
    profileEpoch: profile.epoch,
    deletionEpoch: profile.deletionEpoch
  )
}
