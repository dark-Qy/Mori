#if DEBUG
  import Foundation
  import MoriDomain
  import MoriPersistence
  import MoriRuntime
  import Testing

  @Suite("Deterministic Mock product bootstrap")
  struct MockProductLoopBootstrapTests {
    @Test("Normal day grants 18, defaults, one event, and one task")
    func normalDayManifest() throws {
      let fixture = try replayedBootstrap(
        scenarioID: MockScenarioID("mock1")
      )

      #expect(fixture.replay.unresolved.isEmpty)
      #expect(fixture.replay.state.coinLedger.balance == 18)
      #expect(
        Set(
          fixture.replay.state.collection.ownership.map(
            \.cosmeticID
          )
        )
          == [
            MockProductLoopBootstrap.defaultOutfitID,
            MockProductLoopBootstrap.defaultSceneID,
          ]
      )
      #expect(
        fixture.replay.state.collection.equipped[.outfit]?
          .cosmeticID
          == MockProductLoopBootstrap.defaultOutfitID
      )
      #expect(
        fixture.replay.state.collection.equipped[.scene]?
          .cosmeticID
          == MockProductLoopBootstrap.defaultSceneID
      )
      #expect(fixture.replay.state.passiveEvents.count == 1)
      #expect(fixture.replay.state.tasks.count == 1)
      #expect(fixture.replay.state.tasks[0].kind == .reflectOnDay)
      #expect(fixture.replay.state.tasks[0].rewardTier == .smallest)
      #expect(
        fixture.replay.state.tasks[0].completionPolicy
          == .userConfirmation
      )
    }

    @Test("Daily moments Mock selects the polar bear identity")
    func dailyMomentsSelectPolarBear() throws {
      let fixture = try replayedBootstrap(
        scenarioID: MockScenarioID("mock5")
      )

      #expect(fixture.replay.unresolved.isEmpty)
      #expect(fixture.replay.state.selectedIdentity == .polarBear)
      #expect(
        fixture.envelopes.contains {
          if case .identitySelection(let record) = $0.payload {
            return record.identity == .polarBear
          }
          return false
        }
      )
    }

    @Test("Disabled and neutral scenarios keep only permitted records")
    func neutralScenarios() throws {
      let disabled = try replayedBootstrap(
        scenarioID: MockScenarioID("mock1"),
        enabled: false
      )
      #expect(disabled.envelopes.count == 5)
      #expect(disabled.replay.state.coinLedger.balance == 18)
      #expect(disabled.replay.state.derivedFacts.isEmpty)
      #expect(disabled.replay.state.passiveEvents.isEmpty)
      #expect(disabled.replay.state.tasks.isEmpty)

      let denied = try replayedBootstrap(
        scenarioID: MoriMockScenario.deniedPermission.id
      )
      #expect(denied.replay.unresolved.isEmpty)
      #expect(denied.replay.state.coinLedger.balance == 18)
      #expect(denied.replay.state.passiveEvents.isEmpty)
      #expect(denied.replay.state.tasks.isEmpty)

      let stale = try replayedBootstrap(
        scenarioID: MoriMockScenario.staleEvidence.id
      )
      #expect(stale.replay.unresolved.isEmpty)
      #expect(stale.replay.state.coinLedger.balance == 18)
      #expect(stale.replay.state.derivedFacts.isEmpty == false)
      #expect(stale.replay.state.passiveEvents.isEmpty)
      #expect(stale.replay.state.tasks.isEmpty)
    }

    @Test("Unknown and real profiles fail closed")
    func invalidSourceFailsClosed() throws {
      let sensing = testSensing()
      let unknown = testProfile(
        scenarioID: MockScenarioID("not-reviewed")
      )
      let real = RuntimeProfile(
        id: ProfileID("real-bootstrap"),
        epoch: unknown.epoch,
        deletionEpoch: unknown.deletionEpoch,
        source: .real
      )
      let bootstrap = MockProductLoopBootstrap()

      #expect(
        throws:
          MockProductLoopBootstrapError.unknownScenario(
            MockScenarioID("not-reviewed")
          )
      ) {
        _ = try bootstrap.envelopes(
          profile: unknown,
          sensing: sensing
        )
      }
      #expect(throws: MockProductLoopBootstrapError.realProfile) {
        _ = try bootstrap.envelopes(
          profile: real,
          sensing: sensing
        )
      }
    }

    @Test("Independent peers and retries produce identical envelopes")
    func deterministicAcrossPeersAndRetries() throws {
      let profile = testProfile(
        scenarioID: MockScenarioID("activity_high")
      )
      let sensing = testSensing()
      let bootstrap = MockProductLoopBootstrap()

      let first = try bootstrap.envelopes(
        profile: profile,
        sensing: sensing
      )
      let retry = try bootstrap.envelopes(
        profile: profile,
        sensing: sensing
      )

      #expect(first == retry)
      #expect(
        Set(first.map(\.eventID)).count == first.count
      )
      #expect(
        Set(
          first.map {
            "\($0.originDeviceID):\($0.originSequence)"
          }
        ).count == first.count
      )
    }

    @Test("Profile source and deletion fences change stable IDs")
    func scopeIsolation() throws {
      let sensing = testSensing()
      let first = testProfile(
        scenarioID: MockScenarioID("mock1")
      )
      let sourceChanged = RuntimeProfile(
        id: first.id,
        epoch: first.epoch,
        deletionEpoch: first.deletionEpoch,
        source: .mock(
          scenarioID: MoriMockScenario.normalDay.id,
          selectionEpoch: first.epoch
        )
      )
      let deletionChanged = RuntimeProfile(
        id: first.id,
        epoch: first.epoch,
        deletionEpoch: DeletionEpoch(
          requestID: DeletionRequestID("replacement-delete"),
          revision: LamportRevision(
            counter: 99,
            originDeviceID: "authority"
          )
        ),
        source: first.source
      )
      let bootstrap = MockProductLoopBootstrap()

      let firstIDs = Set(
        try bootstrap.envelopes(
          profile: first,
          sensing: sensing
        ).map(\.eventID)
      )
      let sourceIDs = Set(
        try bootstrap.envelopes(
          profile: sourceChanged,
          sensing: sensing
        ).map(\.eventID)
      )
      let deletionIDs = Set(
        try bootstrap.envelopes(
          profile: deletionChanged,
          sensing: sensing
        ).map(\.eventID)
      )

      #expect(firstIDs.isDisjoint(with: sourceIDs))
      #expect(firstIDs.isDisjoint(with: deletionIDs))
    }
  }

  private struct ReplayedBootstrap {
    let envelopes: [ExperienceSyncEnvelope]
    let replay: ProfileReplayResult
  }

  private func replayedBootstrap(
    scenarioID: MockScenarioID,
    enabled: Bool = true
  ) throws -> ReplayedBootstrap {
    let profile = testProfile(scenarioID: scenarioID)
    let sensing = testSensing(enabled: enabled)
    let initialState = try ProfileInitialStateFactory().make(
      profile: profile,
      sensing: sensing
    )
    let envelopes = try MockProductLoopBootstrap().envelopes(
      profile: profile,
      sensing: sensing
    )
    let ledger = try ProfileLedger(
      initialState: initialState,
      envelopes: envelopes
    )
    return ReplayedBootstrap(
      envelopes: envelopes,
      replay: ledger.replay()
    )
  }

  private func testProfile(
    scenarioID: MockScenarioID
  ) -> RuntimeProfile {
    let epoch = ProfileEpoch(
      LamportRevision(
        counter: 10,
        originDeviceID: "profile-authority"
      )
    )
    return RuntimeProfile(
      id: ProfileID("mock-\(scenarioID.rawValue)"),
      epoch: epoch,
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("initial-delete"),
        revision: LamportRevision(
          counter: 1,
          originDeviceID: "deletion-authority"
        )
      ),
      source: .mock(
        scenarioID: scenarioID,
        selectionEpoch: epoch
      )
    )
  }

  private func testSensing(
    enabled: Bool = true
  ) -> CompanionSensingPreference {
    CompanionSensingPreference(
      enabled: enabled,
      epoch: SensingEpoch(
        LamportRevision(
          counter: 20,
          originDeviceID: "sensing-authority"
        )
      )
    )
  }
#endif
