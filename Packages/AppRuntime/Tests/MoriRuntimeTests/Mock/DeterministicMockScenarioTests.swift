#if DEBUG
  import Foundation
  import MoriDomain
  import MoriRuntime
  import Testing

  @Suite("Deterministic G2 Mock scenarios")
  struct DeterministicMockScenarioTests {
    @Test("Every required scenario is deterministic and exercises its intended branch")
    func requiredScenarios() throws {
      let sensingEpoch = SensingEpoch(
        LamportRevision(counter: 50, originDeviceID: "watch")
      )
      let catalog = MoriMockScenarioCatalog()

      for scenario in MoriMockScenario.allCases {
        let profile = try profile(for: scenario)
        let first = try #require(
          catalog.seed(
            for: scenario.id,
            profile: profile,
            sensingEpoch: sensingEpoch
          )
        )
        let second = try #require(
          catalog.seed(
            for: scenario.id,
            profile: profile,
            sensingEpoch: sensingEpoch
          )
        )
        #expect(first.scenario == second.scenario)
        #expect(first.evaluatedAt == second.evaluatedAt)
        #expect(first.activation == second.activation)
        #expect(first.facts == second.facts)

        let outcome = PassiveInferencePipeline().evaluate(
          PassiveInferenceRequest(
            profile: profile,
            sensingEpoch: sensingEpoch,
            evaluatedAt: first.evaluatedAt,
            localHour: first.localHour,
            activation: first.activation,
            facts: first.facts
          )
        )
        switch scenario {
        case .normalDay, .offlineSynchronization:
          #expect(outcome.eventProposal?.kind == .sharedWalk)
        case .fastWalking:
          #expect(outcome.eventProposal?.kind == .fastPace)
        case .walkAndStop:
          #expect(outcome.eventProposal?.kind == .pausedTogether)
        case .lateSleep:
          #expect(outcome.eventProposal?.kind == .sleepReflection)
        case .deniedPermission:
          #expect(outcome == .neutral(.permissionDenied))
        case .staleEvidence:
          #expect(outcome == .neutral(.noUsableEvidence))
        }
      }
    }

    @Test("Unknown and profile-mismatched scenarios never fall back to production")
    func invalidScenario() throws {
      let profile = try profile(for: .normalDay)
      let epoch = SensingEpoch(
        LamportRevision(counter: 50, originDeviceID: "watch")
      )
      let catalog = MoriMockScenarioCatalog()

      #expect(
        catalog.seed(
          for: MockScenarioID("unknown"),
          profile: profile,
          sensingEpoch: epoch
        ) == nil
      )
      #expect(
        catalog.seed(
          for: MoriMockScenario.fastWalking.id,
          profile: profile,
          sensingEpoch: epoch
        ) == nil
      )
    }

    private func profile(for scenario: MoriMockScenario) throws -> RuntimeProfile {
      try MockProfileDerivation.selection(
        scenarioID: scenario.id,
        revision: LamportRevision(counter: 10, originDeviceID: "phone")
      ).profile
    }
  }
#endif
