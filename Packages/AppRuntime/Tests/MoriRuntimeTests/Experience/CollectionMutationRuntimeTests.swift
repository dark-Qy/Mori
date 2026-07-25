#if DEBUG
  import Foundation
  import MoriDomain
  import MoriPersistence
  import MoriRuntime
  import Testing

  @Suite("Atomic collection mutations")
  struct CollectionMutationRuntimeTests {
    @Test("Purchase resolves the authoritative price and survives retry")
    func authoritativePurchaseAndRetry() async throws {
      let fixture = try await collectionFixture()
      let runtime = CollectionMutationRuntime(
        originDeviceID: "iphone",
        store: fixture.sync
      )
      let operation = CollectionOperationID(
        rawValue: "buy-scarf-once"
      )

      let first = try await runtime.purchase(
        cosmeticID: CosmeticID("scarf"),
        operationID: operation,
        at: fixture.date
      )
      let retry = try await runtime.purchase(
        cosmeticID: CosmeticID("scarf"),
        operationID: operation,
        at: fixture.date
      )
      let replay = try await fixture.sync.currentLedger().replay()

      #expect(first.didRecordPurchase)
      #expect(first.balance == 10)
      #expect(retry.didRecordPurchase == false)
      #expect(retry.eventID == first.eventID)
      #expect(retry.balance == 10)
      #expect(
        replay.state.collection.owns(CosmeticID("scarf"))
      )
      #expect(
        replay.state.coinLedger.transactions.filter {
          if case .cosmeticPurchase(CosmeticID("scarf")) =
            $0.reason
          {
            return true
          }
          return false
        }.count == 1
      )
    }

    @Test("One operation cannot purchase two different cosmetics")
    func idempotencyKeyReuseFailsClosed() async throws {
      let fixture = try await collectionFixture()
      let runtime = CollectionMutationRuntime(
        originDeviceID: "iphone",
        store: fixture.sync
      )
      let operation = CollectionOperationID(rawValue: "one-command")
      _ = try await runtime.purchase(
        cosmeticID: CosmeticID("leaf"),
        operationID: operation,
        at: fixture.date
      )

      await #expect(
        throws: CollectionMutationRuntimeError.idempotencyKeyReuse
      ) {
        _ = try await runtime.purchase(
          cosmeticID: CosmeticID("star"),
          operationID: operation,
          at: fixture.date
        )
      }
      await #expect(
        throws: CollectionMutationRuntimeError.idempotencyKeyReuse
      ) {
        _ = try await runtime.equip(
          cosmeticID: CosmeticID("star"),
          operationID: operation,
          at: fixture.date
        )
      }
      #expect(
        try await fixture.sync.currentLedger().replay().state
          .coinLedger.balance == 14
      )
    }

    @Test("Unknown items and invalid operation IDs cannot write")
    func invalidInputsFailClosed() async throws {
      let fixture = try await collectionFixture()
      let runtime = CollectionMutationRuntime(
        originDeviceID: "iphone",
        store: fixture.sync
      )
      let before = try await fixture.sync.currentLedger().envelopes
        .count

      await #expect(
        throws:
          CollectionMutationRuntimeError.unknownItem(
            CosmeticID("forged")
          )
      ) {
        _ = try await runtime.purchase(
          cosmeticID: CosmeticID("forged"),
          operationID: CollectionOperationID(rawValue: "forged"),
          at: fixture.date
        )
      }
      await #expect(
        throws: CollectionMutationRuntimeError.invalidOperationID
      ) {
        _ = try await runtime.purchase(
          cosmeticID: CosmeticID("scarf"),
          operationID: CollectionOperationID(
            rawValue: String(repeating: "x", count: 129)
          ),
          at: fixture.date
        )
      }
      #expect(
        try await fixture.sync.currentLedger().envelopes.count
          == before
      )
    }

    @Test("Free bootstrap defaults can be equipped again")
    func equipDefaultAgain() async throws {
      let fixture = try await collectionFixture()
      let runtime = CollectionMutationRuntime(
        originDeviceID: "iphone",
        store: fixture.sync
      )
      _ = try await runtime.purchase(
        cosmeticID: CosmeticID("scarf"),
        operationID: CollectionOperationID(rawValue: "buy-scarf"),
        at: fixture.date
      )
      _ = try await runtime.equip(
        cosmeticID: CosmeticID("scarf"),
        operationID: CollectionOperationID(rawValue: "equip-scarf"),
        at: fixture.date
      )

      let result = try await runtime.equip(
        cosmeticID: MockProductLoopBootstrap.defaultOutfitID,
        operationID: CollectionOperationID(rawValue: "equip-default"),
        at: fixture.date
      )
      let replay = try await fixture.sync.currentLedger().replay()

      #expect(result.didRecordTransition)
      #expect(result.isEquipped)
      #expect(
        replay.state.collection.equipped[.outfit]?.cosmeticID
          == MockProductLoopBootstrap.defaultOutfitID
      )
    }

    @Test("Successful no-op commands also reserve their operation ID")
    func noOpCommandsConsumeOperationID() async throws {
      let fixture = try await collectionFixture()
      let runtime = CollectionMutationRuntime(
        originDeviceID: "iphone",
        store: fixture.sync
      )
      _ = try await runtime.purchase(
        cosmeticID: CosmeticID("leaf"),
        operationID: CollectionOperationID(rawValue: "buy-leaf"),
        at: fixture.date
      )
      let ownedReceipt = CollectionOperationID(
        rawValue: "already-owned-leaf"
      )
      let owned = try await runtime.purchase(
        cosmeticID: CosmeticID("leaf"),
        operationID: ownedReceipt,
        at: fixture.date
      )
      #expect(owned.didRecordPurchase == false)
      #expect(owned.eventID != nil)
      #expect(owned.balance == 14)

      await #expect(
        throws: CollectionMutationRuntimeError.idempotencyKeyReuse
      ) {
        _ = try await runtime.equip(
          cosmeticID: MockProductLoopBootstrap.defaultOutfitID,
          operationID: ownedReceipt,
          at: fixture.date
        )
      }

      let equippedReceipt = CollectionOperationID(
        rawValue: "already-equipped-default"
      )
      let equipped = try await runtime.equip(
        cosmeticID: MockProductLoopBootstrap.defaultOutfitID,
        operationID: equippedReceipt,
        at: fixture.date
      )
      #expect(equipped.didRecordTransition)
      #expect(equipped.isEquipped)
      await #expect(
        throws: CollectionMutationRuntimeError.idempotencyKeyReuse
      ) {
        _ = try await runtime.purchase(
          cosmeticID: CosmeticID("star"),
          operationID: equippedReceipt,
          at: fixture.date
        )
      }
    }

    @Test("Concurrent purchases serialize to one debit")
    func concurrentPurchaseIsAtomic() async throws {
      let fixture = try await collectionFixture()
      let runtime = CollectionMutationRuntime(
        originDeviceID: "iphone",
        store: fixture.sync
      )

      async let first = runtime.purchase(
        cosmeticID: CosmeticID("scarf"),
        operationID: CollectionOperationID(rawValue: "concurrent-a"),
        at: fixture.date
      )
      async let second = runtime.purchase(
        cosmeticID: CosmeticID("scarf"),
        operationID: CollectionOperationID(rawValue: "concurrent-b"),
        at: fixture.date
      )
      let results = try await [first, second]
      let replay = try await fixture.sync.currentLedger().replay()

      #expect(
        results.filter(\.didRecordPurchase).count == 1
      )
      #expect(replay.state.coinLedger.balance == 10)
      #expect(
        replay.state.collection.ownership.filter {
          $0.cosmeticID == CosmeticID("scarf")
        }.count == 1
      )
    }
  }

  private typealias CollectionLedger =
    ProfileLedgerRepository<InMemoryProfileLedgerStorage>
  private typealias CollectionSync =
    ExperienceSyncRuntime<
      InMemoryExperienceSyncOutboxStorage,
      CollectionLedger
    >

  private struct CollectionFixture {
    let sync: CollectionSync
    let date: Date
  }

  private func collectionFixture() async throws
    -> CollectionFixture
  {
    let profile = ExperienceTestFixtures.profile()
    let sensing = CompanionSensingPreference(
      enabled: true,
      epoch: ExperienceTestFixtures.sensingEpoch()
    )
    let state = try ProfileInitialStateFactory().make(
      profile: profile,
      sensing: sensing
    )
    let ledger = CollectionLedger(
      storage: InMemoryProfileLedgerStorage(),
      initialState: state
    )
    let sync = CollectionSync(
      profile: profile,
      outboxStorage: InMemoryExperienceSyncOutboxStorage(),
      ledger: ledger
    )
    _ = try await MockProductLoopBootstrap().bootstrap(
      profile: profile,
      sensing: sensing,
      store: sync
    )
    return CollectionFixture(
      sync: sync,
      date: ExperienceTestFixtures.date(
        "2026-07-24T12:30:00Z"
      )
    )
  }
#endif
