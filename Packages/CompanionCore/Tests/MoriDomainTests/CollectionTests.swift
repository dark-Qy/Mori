import Foundation
import Testing

@testable import MoriDomain

@Suite("Collection purchase and equip")
struct CollectionTests {
  @Test("Purchase debits once, grants ownership once, and equips only owned items")
  func purchaseAndEquip() {
    let profile = MoriTestFixtures.profile()
    var ledger = CoinLedger(
      header: MoriTestFixtures.header(CoinLedgerID("coins"), profile: profile)
    )
    for index in 0..<2 {
      #expect(
        ledger.apply(
          MoriTestFixtures.reward(
            "fund-\(index)",
            settlementID: TaskSettlementID("fund-settlement-\(index)"),
            profile: profile,
            revision: MoriTestFixtures.revision(UInt64(index + 1)),
            tier: .standard
          ),
          in: profile
        ) == .applied
      )
    }
    var collection = CollectionState(
      header: MoriTestFixtures.header(CollectionID("collection"), profile: profile)
    )
    let item = CosmeticCatalogItem(
      id: CosmeticID("raincoat"),
      slot: .outfit,
      coinPrice: 4
    )
    let debit = CoinTransaction(
      header: MoriTestFixtures.header(
        CoinTransactionID("buy-raincoat"),
        profile: profile
      ),
      revision: MoriTestFixtures.revision(3),
      authoredAt: MoriTestFixtures.now,
      direction: .debit,
      amount: 4,
      reason: .cosmeticPurchase(item.id)
    )
    let ownership = CollectionOwnershipRecord(
      header: MoriTestFixtures.header(
        CollectionOwnershipID("own-raincoat"),
        profile: profile
      ),
      cosmeticID: item.id,
      slot: item.slot,
      acquiredAt: MoriTestFixtures.now,
      purchaseTransactionID: debit.header.recordID,
      revision: MoriTestFixtures.revision(3)
    )

    guard
      case .purchased(let result) = CollectionReducer.purchase(
        item: item,
        ownership: ownership,
        transaction: debit,
        collection: collection,
        coinLedger: ledger,
        profile: profile
      )
    else {
      Issue.record("expected an affordable purchase")
      return
    }
    ledger = result.coinLedger
    collection = result.collection
    #expect(ledger.balance == 0)
    #expect(collection.owns(item.id))

    #expect(
      CollectionReducer.purchase(
        item: item,
        ownership: ownership,
        transaction: debit,
        collection: collection,
        coinLedger: ledger,
        profile: profile
      ) == .duplicate
    )

    let equip = CollectionTransition(
      header: MoriTestFixtures.header(
        CollectionTransitionID("equip-raincoat"),
        profile: profile
      ),
      cosmeticID: item.id,
      slot: item.slot,
      revision: MoriTestFixtures.revision(4)
    )
    #expect(collection.equip(equip, catalogItem: item, in: profile) == .applied)
    #expect(collection.equipped[.outfit]?.cosmeticID == item.id)
    #expect(collection.equip(equip, catalogItem: item, in: profile) == .duplicate)
  }

  @Test("Insufficient funds and unowned equip leave both ledgers unchanged")
  func rejectedMutationsAreAtomic() {
    let profile = MoriTestFixtures.profile()
    let ledger = CoinLedger(
      header: MoriTestFixtures.header(CoinLedgerID("coins"), profile: profile)
    )
    var collection = CollectionState(
      header: MoriTestFixtures.header(CollectionID("collection"), profile: profile)
    )
    let item = CosmeticCatalogItem(
      id: CosmeticID("scarf"),
      slot: .accessory,
      coinPrice: 2
    )
    let debit = CoinTransaction(
      header: MoriTestFixtures.header(CoinTransactionID("buy-scarf"), profile: profile),
      revision: MoriTestFixtures.revision(2),
      authoredAt: MoriTestFixtures.now,
      direction: .debit,
      amount: 2,
      reason: .cosmeticPurchase(item.id)
    )
    let ownership = CollectionOwnershipRecord(
      header: MoriTestFixtures.header(
        CollectionOwnershipID("own-scarf"),
        profile: profile
      ),
      cosmeticID: item.id,
      slot: item.slot,
      acquiredAt: MoriTestFixtures.now,
      purchaseTransactionID: debit.header.recordID,
      revision: MoriTestFixtures.revision(2)
    )

    #expect(
      CollectionReducer.purchase(
        item: item,
        ownership: ownership,
        transaction: debit,
        collection: collection,
        coinLedger: ledger,
        profile: profile
      ) == .rejected(.insufficientCoins)
    )
    #expect(ledger.balance == 0)
    #expect(collection.ownership.isEmpty)

    let equip = CollectionTransition(
      header: MoriTestFixtures.header(
        CollectionTransitionID("equip-scarf"),
        profile: profile
      ),
      cosmeticID: item.id,
      slot: item.slot,
      revision: MoriTestFixtures.revision(3)
    )
    #expect(collection.equip(equip, catalogItem: item, in: profile) == .rejected(.itemNotOwned))
    #expect(collection.equipped.isEmpty)
  }
}
