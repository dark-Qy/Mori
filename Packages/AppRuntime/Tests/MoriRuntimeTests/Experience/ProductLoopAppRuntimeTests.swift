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

    @Test("Foreground glance terminalizes replacement through ledger and outbox")
    func foregroundGlancePersistsReplacement() async throws {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let profile = ExperienceTestFixtures.profile()
      let runtime = try ProductLoopAppRuntime(
        applicationSupportURL: root,
        profile: profile,
        sensing: testFacadeSensing(),
        originDeviceID: "watch"
      )
      _ = try await runtime.activate()
      let initial = try await runtime.snapshot()
      let older = try #require(
        initial.localState.passiveEvents.first
      )
      let newerFixture = try makeNewerGlance(
        from: older,
        profile: profile,
        ledger: persistedLedger(for: runtime)
      )
      try await receive(
        newerFixture.envelope,
        in: runtime,
        profile: profile
      )
      let pendingBefore =
        try await runtime.pendingSyncEventCount()
      let now =
        newerFixture.event.observedAt.addingTimeInterval(1)

      let presentation = try await runtime.foregroundGlance(
        at: now,
        reminderMode: .gentleHaptic,
        quietHours: CompanionQuietHours(
          startMinute: 1,
          endMinute: 2
        ),
        timeZone: TimeZone(secondsFromGMT: 0)!
      )

      #expect(
        presentation?.eventID
          == newerFixture.event.header.recordID
      )
      #expect(presentation?.shouldPlayHaptic == true)
      let after = try await runtime.snapshot()
      #expect(
        after.localState.passiveEvents.first {
          $0.header.recordID == older.header.recordID
        }?.reminderState
          == .replaced(
            by: newerFixture.event.header.recordID,
            at: now
          )
      )
      #expect(
        after.localState.passiveEvents.first {
          $0.header.recordID
            == newerFixture.event.header.recordID
        }?.reminderState == .presented(at: now)
      )
      #expect(
        try await runtime.pendingSyncEventCount()
          == pendingBefore + 2
      )

      let relaunched = try ProductLoopAppRuntime(
        applicationSupportURL: root,
        profile: profile,
        sensing: testFacadeSensing(),
        originDeviceID: "watch"
      )
      #expect(
        try await relaunched.foregroundGlance(
          at: now,
          reminderMode: .gentleHaptic,
          quietHours: CompanionQuietHours(
            startMinute: 1,
            endMinute: 2
          ),
          timeZone: TimeZone(secondsFromGMT: 0)!
        ) == nil
      )
      #expect(
        try await relaunched.pendingSyncEventCount()
          == pendingBefore + 2
      )
    }

    @Test("Expired foreground glance writes one terminal envelope")
    func foregroundGlancePersistsExpiry() async throws {
      let root = temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let runtime = try ProductLoopAppRuntime(
        applicationSupportURL: root,
        profile: ExperienceTestFixtures.profile(),
        sensing: testFacadeSensing(),
        originDeviceID: "watch"
      )
      _ = try await runtime.activate()
      let event = try #require(
        try await runtime.snapshot().localState.passiveEvents.first
      )
      let pendingBefore =
        try await runtime.pendingSyncEventCount()
      let now = event.observedAt.addingTimeInterval(121)

      #expect(
        try await runtime.foregroundGlance(
          at: now,
          reminderMode: .wristRaise,
          quietHours: CompanionQuietHours(
            startMinute: 1,
            endMinute: 2
          ),
          timeZone: TimeZone(secondsFromGMT: 0)!
        ) == nil
      )
      #expect(
        try await runtime.snapshot().localState.passiveEvents.first?
          .reminderState == .expired(at: now)
      )
      #expect(
        try await runtime.pendingSyncEventCount()
          == pendingBefore + 1
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

  private func makeNewerGlance(
    from older: PassiveCompanionEvent,
    profile: RuntimeProfile,
    ledger: ProfileLedger
  ) throws -> (
    event: PassiveCompanionEvent,
    envelope: ExperienceSyncEnvelope
  ) {
    let origin = "paired-test"
    let counter =
      (ledger.envelopes.map(\.revision.counter).max() ?? 0) + 1
    let revision = LamportRevision(
      counter: counter,
      originDeviceID: origin
    )
    let event = PassiveCompanionEvent(
      header: ExperienceTestFixtures.header(
        EventID("facade-newer-glance"),
        profile: profile
      ),
      sensingEpoch: older.sensingEpoch,
      kind: .pausedTogether,
      observedAt: older.observedAt.addingTimeInterval(10),
      confidence: .exact,
      evidence: older.evidence,
      presentationDeadline:
        older.observedAt.addingTimeInterval(130),
      replacementKey: "facade-latest",
      taskCooldownKey: nil,
      memoryEligibility: .ineligible,
      sceneID: nil,
      moriActionID: "facade.pause",
      reminderRevision: revision
    )
    let envelope = ExperienceSyncEnvelope(
      eventID: ExperienceEventID("facade-newer-envelope"),
      eventType: .passiveEvent,
      profileID: profile.id,
      profileEpoch: profile.epoch,
      deletionEpoch: profile.deletionEpoch,
      profileSource: profile.source,
      originDeviceID: origin,
      originSequence: 1,
      revision: revision,
      observedAt: event.observedAt,
      authoredAt: event.observedAt,
      privacyClass: .approvedDerived,
      tombstone: nil,
      sourceEventID: nil,
      settlementID: nil,
      payload: .passiveEvent(event)
    )
    return (event, envelope)
  }

  private func receive(
    _ envelope: ExperienceSyncEnvelope,
    in runtime: ProductLoopAppRuntime,
    profile: RuntimeProfile
  ) async throws {
    let transfer = ExperienceSyncTransfer(
      scope: ExperienceSyncScope(profile: profile),
      envelopeBytes: [
        try ExperienceEnvelopeCodec().encode(envelope)
      ]
    )
    _ = try await runtime.receive(
      ExperienceSyncWireCodec().encode(transfer)
    )
  }
#endif
