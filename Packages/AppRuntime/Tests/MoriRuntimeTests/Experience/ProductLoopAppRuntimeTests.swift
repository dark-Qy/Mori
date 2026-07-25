#if DEBUG
  import Foundation
  import MoriDomain
  import MoriPersistence
  import MoriRuntime
  import Testing

  @Suite("File-backed product-loop facade")
  struct ProductLoopAppRuntimeTests {
    @Test("Restart preserves one bootstrap and completed purchase loop")
    func restartAndRetryAreIdempotent() async throws {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let profile = ExperienceTestFixtures.profile()
      let sensing = testFacadeSensing()
      let first = try ProductLoopAppRuntime(
        applicationSupportURL: root,
        profile: profile,
        sensing: sensing,
        originDeviceID: "iphone"
      )

      let initial = try await first.activate()
      let task = try #require(initial.tasks.first)
      #expect(initial.coins.balance == 18)
      let settlement = try await first.completeTask(
        taskID: task.id,
        method: .userConfirmed,
        at: Date(timeIntervalSince1970: 1_760_000_100)
      )
      #expect(settlement.balance == 19)
      let purchase = try await first.purchase(
        cosmeticID: CosmeticID("scarf"),
        operationID: CollectionOperationID(
          rawValue: "facade-buy-scarf"
        ),
        at: Date(timeIntervalSince1970: 1_760_000_200)
      )
      #expect(purchase.balance == 11)

      let relaunched = try ProductLoopAppRuntime(
        applicationSupportURL: root,
        profile: profile,
        sensing: sensing,
        originDeviceID: "iphone"
      )
      let restored = try await relaunched.activate()
      let retry = try await relaunched.purchase(
        cosmeticID: CosmeticID("scarf"),
        operationID: CollectionOperationID(
          rawValue: "facade-buy-scarf"
        ),
        at: Date(timeIntervalSince1970: 1_760_000_200)
      )

      #expect(restored.coins.balance == 11)
      #expect(
        restored.coins.transactions.filter {
          if case .welcomeGrant(schemaVersion: 1) = $0.reason {
            return true
          }
          return false
        }.count == 1
      )
      #expect(
        restored.collection.ownership.filter {
          $0.cosmeticID == CosmeticID("scarf")
        }.count == 1
      )
      #expect(retry.didRecordPurchase == false)
      #expect(retry.balance == 11)
    }

    @Test("Snapshot exposes local values without weakening projection")
    func localSnapshotAndProjection() async throws {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let runtime = try ProductLoopAppRuntime(
        applicationSupportURL: root,
        profile: ExperienceTestFixtures.profile(),
        sensing: testFacadeSensing(),
        originDeviceID: "watch"
      )
      _ = try await runtime.activate()

      let snapshot = try await runtime.snapshot()

      #expect(
        snapshot.localState.derivedFacts.contains {
          if case .stepTotal(3_250) = $0.value { return true }
          return false
        }
      )
      #expect(snapshot.convergenceProjection.facts.isEmpty == false)
      #expect(
        snapshot.convergenceProjection.coins.balance == 18
      )
    }

    @Test("Real profile never receives Mock bootstrap content")
    func realProfileDoesNotBootstrap() async throws {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let mock = ExperienceTestFixtures.profile()
      let profile = RuntimeProfile(
        id: ProfileID("real-product-loop"),
        epoch: mock.epoch,
        deletionEpoch: mock.deletionEpoch,
        source: .real
      )
      let runtime = try ProductLoopAppRuntime(
        applicationSupportURL: root,
        profile: profile,
        sensing: testFacadeSensing(),
        originDeviceID: "iphone"
      )

      #expect(
        try await runtime.bootstrapIfNeeded() == .notApplicable
      )
      let snapshot = try await runtime.snapshot()
      #expect(snapshot.localState.coinLedger.balance == 0)
      #expect(snapshot.localState.collection.ownership.isEmpty)
      #expect(snapshot.localState.derivedFacts.isEmpty)
      #expect(snapshot.localState.tasks.isEmpty)
    }

    @Test("Source and deletion scopes use isolated file namespaces")
    func fileNamespaceIsolation() async throws {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let firstProfile = ExperienceTestFixtures.profile()
      let realProfile = RuntimeProfile(
        id: firstProfile.id,
        epoch: firstProfile.epoch,
        deletionEpoch: firstProfile.deletionEpoch,
        source: .real
      )
      let deletedProfile = RuntimeProfile(
        id: firstProfile.id,
        epoch: firstProfile.epoch,
        deletionEpoch: DeletionEpoch(
          requestID: DeletionRequestID("new-delete-fence"),
          revision: LamportRevision(
            counter: 50,
            originDeviceID: "authority"
          )
        ),
        source: firstProfile.source
      )
      let sensing = testFacadeSensing()
      let mock = try ProductLoopAppRuntime(
        applicationSupportURL: root,
        profile: firstProfile,
        sensing: sensing,
        originDeviceID: "iphone"
      )
      let real = try ProductLoopAppRuntime(
        applicationSupportURL: root,
        profile: realProfile,
        sensing: sensing,
        originDeviceID: "iphone"
      )
      let deleted = try ProductLoopAppRuntime(
        applicationSupportURL: root,
        profile: deletedProfile,
        sensing: sensing,
        originDeviceID: "iphone"
      )
      _ = try await mock.activate()
      _ = try await deleted.activate()

      #expect(mock.namespaceRootURL != real.namespaceRootURL)
      #expect(mock.namespaceRootURL != deleted.namespaceRootURL)
      #expect(
        try await mock.projection().coins.balance == 18
      )
      #expect(
        try await real.projection().coins.balance == 0
      )
      #expect(
        try await deleted.projection().coins.balance == 18
      )
    }

    @Test("Facade gate keeps concurrent local origin sequences unique")
    func concurrentCommandsUseOneAllocatorWindow() async throws {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let runtime = try ProductLoopAppRuntime(
        applicationSupportURL: root,
        profile: ExperienceTestFixtures.profile(),
        sensing: testFacadeSensing(),
        originDeviceID: "iphone"
      )
      let initial = try await runtime.activate()
      let taskID = try #require(initial.tasks.first?.id)

      async let completion = runtime.completeTask(
        taskID: taskID,
        method: .userConfirmed,
        at: Date(timeIntervalSince1970: 1_760_000_100)
      )
      async let purchase = runtime.purchase(
        cosmeticID: CosmeticID("leaf"),
        operationID: CollectionOperationID(
          rawValue: "parallel-buy-leaf"
        ),
        at: Date(timeIntervalSince1970: 1_760_000_200)
      )
      _ = try await (completion, purchase)

      let ledger = try persistedLedger(for: runtime)
      let local = ledger.envelopes.filter {
        $0.originDeviceID == "iphone"
      }
      #expect(
        Set(local.map(\.originSequence)).count == local.count
      )
      #expect(
        Set(
          local.map {
            "\($0.revision.counter):\($0.revision.originDeviceID)"
          }
        ).count == local.count
      )
      #expect(ledger.replay().state.coinLedger.balance == 15)
    }

    @Test("Higher sensing authority adds fresh facts without a second grant")
    func sensingReconciliation() async throws {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let runtime = try ProductLoopAppRuntime(
        applicationSupportURL: root,
        profile: ExperienceTestFixtures.profile(),
        sensing: testFacadeSensing(),
        originDeviceID: "iphone"
      )
      _ = try await runtime.activate()
      let before = try await runtime.snapshot()
      let higher = CompanionSensingPreference(
        enabled: true,
        epoch: SensingEpoch(
          LamportRevision(
            counter: 21,
            originDeviceID: "sensing-authority"
          )
        )
      )

      #expect(
        try await runtime.reconcileSensing(
          higher,
          effectiveAt: Date(timeIntervalSince1970: 1_760_000_300)
        ) == .applied
      )
      let after = try await runtime.snapshot()
      let ledger = try persistedLedger(for: runtime)
      let bootstrapSequences = ledger.envelopes
        .filter {
          $0.originDeviceID == "mori-mock-bootstrap"
        }
        .map(\.originSequence)

      #expect(after.localState.currentSensingEpoch == higher.epoch)
      #expect(
        after.localState.derivedFacts.count
          > before.localState.derivedFacts.count
      )
      #expect(after.localState.coinLedger.balance == 18)
      #expect(
        after.localState.coinLedger.transactions.filter {
          if case .welcomeGrant = $0.reason { return true }
          return false
        }.count == 1
      )
      #expect(
        Set(bootstrapSequences).count == bootstrapSequences.count
      )
    }
  }

  private func testFacadeSensing() -> CompanionSensingPreference {
    CompanionSensingPreference(
      enabled: true,
      epoch: SensingEpoch(
        LamportRevision(
          counter: 20,
          originDeviceID: "sensing-authority"
        )
      )
    )
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "mori-product-loop-tests-\(UUID().uuidString)",
      isDirectory: true
    )
  }

  private func persistedLedger(
    for runtime: ProductLoopAppRuntime
  ) throws -> ProfileLedger {
    let fileURL = runtime.namespaceRootURL
      .appendingPathComponent("ledger", isDirectory: true)
      .appendingPathComponent(
        "profile-ledger.json",
        isDirectory: false
      )
    return try ProfileLedgerCodec().decode(
      Data(contentsOf: fileURL)
    )
  }
#endif
