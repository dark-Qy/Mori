import Foundation
import MoriDomain
import Testing

@testable import MoriRuntime

@Suite("Profile-aware dependency composition")
struct RuntimeDependencyCompositionTests {
  @Test("Valid Mock is entirely local and constructs no production adapter")
  func validMockNeverConstructsProduction() async throws {
    let recorder = FactoryRecorder()
    let composer = MoriRuntimeDependencyComposer(
      production: factories(recordingWith: recorder)
    )
    let selection = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("normal-day"),
      revision: LamportRevision(counter: 5, originDeviceID: "phone")
    )

    let bundle = try await composer.compose(for: selection.profile)

    #expect(await recorder.totalCalls() == 0)
    for role in RuntimeDependencyRole.allCases {
      #expect(bundle.service(for: role).isolation == .localOnly)
    }
    #expect(bundle.conversationIsLocalOnly)
    #expect(bundle.touchExchangeIsLocalOnly)
    #expect(bundle.service(for: .chat) is LocalMockConversationService)
    #expect(bundle.service(for: .social) is LocalMockTouchExchangeService)
  }

  @Test("Invalid Mock fails before any production factory is evaluated")
  func invalidMockNeverConstructsProduction() async {
    let recorder = FactoryRecorder()
    let composer = MoriRuntimeDependencyComposer(
      production: factories(recordingWith: recorder)
    )
    let profileRevision = LamportRevision(counter: 6, originDeviceID: "phone")
    let invalidProfile = RuntimeProfile(
      id: ProfileID("invalid-mock"),
      epoch: ProfileEpoch(profileRevision),
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("invalid-mock"),
        revision: profileRevision
      ),
      source: .mock(
        scenarioID: MockScenarioID("normal-day"),
        selectionEpoch: ProfileEpoch(
          LamportRevision(counter: 7, originDeviceID: "phone")
        )
      )
    )

    do {
      _ = try await composer.compose(for: invalidProfile)
      Issue.record("Expected invalid profile composition to fail")
    } catch let error as RuntimeCompositionError {
      #expect(error == .invalidProfile)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await recorder.totalCalls() == 0)
  }

  @Test("Real profile constructs exactly the eight production dependencies")
  func realConstructsProduction() async throws {
    let recorder = FactoryRecorder()
    let composer = MoriRuntimeDependencyComposer(
      production: factories(recordingWith: recorder)
    )
    let revision = LamportRevision(counter: 1, originDeviceID: "phone")
    let profile = RuntimeProfile(
      id: ProfileID("real"),
      epoch: ProfileEpoch(revision),
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("real-baseline"),
        revision: revision
      ),
      source: .real
    )

    let bundle = try await composer.compose(for: profile)

    #expect(await recorder.totalCalls() == RuntimeDependencyRole.allCases.count)
    for role in RuntimeDependencyRole.allCases {
      #expect(await recorder.calls(for: role) == 1)
      #expect(bundle.service(for: role).role == role)
      #expect(bundle.service(for: role).isolation == .production)
    }
    #expect(bundle.conversationIsLocalOnly == false)
    #expect(bundle.touchExchangeIsLocalOnly == false)
  }

  @Test("Production factories cannot smuggle a local or wrong-role service")
  func validatesProductionFactoryResults() async throws {
    let recorder = FactoryRecorder()
    var validFactories = factories(recordingWith: recorder)
    validFactories = ProductionRuntimeFactories(
      health: {
        LocalMockRuntimeService(
          role: .health,
          scenarioID: MockScenarioID("should-not-be-production")
        )
      },
      location: validFactories.location,
      motion: validFactories.motion,
      notification: validFactories.notification,
      chat: validFactories.chat,
      narration: validFactories.narration,
      connectivity: validFactories.connectivity,
      social: validFactories.social
    )
    let revision = LamportRevision(counter: 1, originDeviceID: "phone")
    let real = RuntimeProfile(
      id: ProfileID("real"),
      epoch: ProfileEpoch(revision),
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("real"),
        revision: revision
      ),
      source: .real
    )

    do {
      _ = try await MoriRuntimeDependencyComposer(production: validFactories)
        .compose(for: real)
      Issue.record("Expected local production result to be rejected")
    } catch let error as RuntimeCompositionError {
      #expect(error == .productionFactoryReturnedLocalService(.health))
    }
  }
}

private struct ProductionTestService: MoriRuntimeService {
  let role: RuntimeDependencyRole
  let isolation: RuntimeServiceIsolation = .production
}

private actor FactoryRecorder {
  private var counts: [RuntimeDependencyRole: Int] = [:]

  func make(_ role: RuntimeDependencyRole) -> any MoriRuntimeService {
    counts[role, default: 0] += 1
    return ProductionTestService(role: role)
  }

  func calls(for role: RuntimeDependencyRole) -> Int {
    counts[role, default: 0]
  }

  func totalCalls() -> Int {
    counts.values.reduce(0, +)
  }
}

private func factories(
  recordingWith recorder: FactoryRecorder
) -> ProductionRuntimeFactories {
  ProductionRuntimeFactories(
    health: { await recorder.make(.health) },
    location: { await recorder.make(.location) },
    motion: { await recorder.make(.motion) },
    notification: { await recorder.make(.notification) },
    chat: { await recorder.make(.chat) },
    narration: { await recorder.make(.narration) },
    connectivity: { await recorder.make(.connectivity) },
    social: { await recorder.make(.social) }
  )
}
