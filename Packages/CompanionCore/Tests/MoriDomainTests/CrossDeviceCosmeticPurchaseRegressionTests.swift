import Foundation
import Testing

@testable import MoriDomain

@Suite("Cross-device cosmetic purchase regression")
struct CrossDeviceCosmeticPurchaseRegressionTests {
  @Test("A competing split purchase cannot leave an extra coin debit")
  func splitPurchaseCannotDoubleDebit() {
    let profile = MoriTestFixtures.profile("cross-device-purchase")
    var state = fundedState(profile: profile)
    let item = CosmeticCatalogItem(
      id: CosmeticID("raincoat"),
      slot: .outfit,
      coinPrice: 4
    )
    let phone = purchaseAttempt(
      id: "phone",
      device: "iphone",
      revision: 100,
      item: item,
      profile: profile
    )
    let watch = purchaseAttempt(
      id: "watch",
      device: "watch",
      revision: 101,
      item: item,
      profile: profile
    )

    let beforeSplitAttempt = state
    #expect(
      ProfileReducer.apply(.coinTransaction(phone.transaction), to: &state)
        == .rejected(.invalidPayload)
    )
    #expect(
      ProfileReducer.apply(.collectionOwnership(phone.ownership), to: &state)
        == .rejected(.invalidPayload)
    )
    #expect(state == beforeSplitAttempt)

    #expect(ProfileReducer.apply(phone.mutation(item: item), to: &state) == .applied)
    #expect(ProfileReducer.apply(watch.mutation(item: item), to: &state) == .duplicate)

    #expect(state.collection.ownership.count == 1)
    #expect(state.collection.owns(item.id))
    #expect(state.coinLedger.balance == 4)
    #expect(cosmeticDebits(in: state, for: item.id).count == 1)
  }

  @Test("Atomic competing purchases converge independent of arrival order")
  func atomicPurchaseConvergesAcrossArrivalOrder() {
    let profile = MoriTestFixtures.profile("cross-device-convergence")
    let item = CosmeticCatalogItem(
      id: CosmeticID("scarf"),
      slot: .accessory,
      coinPrice: 4
    )
    let phone = purchaseAttempt(
      id: "phone",
      device: "iphone",
      revision: 100,
      item: item,
      profile: profile
    )
    let watch = purchaseAttempt(
      id: "watch",
      device: "watch",
      revision: 101,
      item: item,
      profile: profile
    )
    var phoneFirst = fundedState(profile: profile)
    var watchFirst = fundedState(profile: profile)

    _ = ProfileReducer.apply(phone.mutation(item: item), to: &phoneFirst)
    _ = ProfileReducer.apply(watch.mutation(item: item), to: &phoneFirst)
    _ = ProfileReducer.apply(watch.mutation(item: item), to: &watchFirst)
    _ = ProfileReducer.apply(phone.mutation(item: item), to: &watchFirst)

    let phoneFirstBeforeRetries = phoneFirst
    _ = ProfileReducer.apply(phone.mutation(item: item), to: &phoneFirst)
    _ = ProfileReducer.apply(watch.mutation(item: item), to: &phoneFirst)
    #expect(phoneFirst == phoneFirstBeforeRetries)

    let watchFirstBeforeRetries = watchFirst
    _ = ProfileReducer.apply(watch.mutation(item: item), to: &watchFirst)
    _ = ProfileReducer.apply(phone.mutation(item: item), to: &watchFirst)
    #expect(watchFirst == watchFirstBeforeRetries)

    #expect(phoneFirst.coinLedger.balance == 4)
    #expect(watchFirst.coinLedger.balance == 4)
    #expect(phoneFirst.collection.ownership.count == 1)
    #expect(watchFirst.collection.ownership.count == 1)
    #expect(phoneFirst.collection == watchFirst.collection)
    #expect(
      cosmeticDebits(in: phoneFirst, for: item.id)
        == cosmeticDebits(in: watchFirst, for: item.id)
    )
  }
}

private struct PurchaseAttempt {
  let ownership: CollectionOwnershipRecord
  let transaction: CoinTransaction

  func mutation(item: CosmeticCatalogItem) -> ProfileMutation {
    .purchase(item: item, ownership: ownership, transaction: transaction)
  }
}

private func fundedState(profile: RuntimeProfile) -> ProfileState {
  var state = MoriTestFixtures.state(profile: profile)
  for index in 0..<4 {
    let transaction = MoriTestFixtures.reward(
      "purchase-funding-\(index)",
      settlementID: TaskSettlementID("purchase-funding-settlement-\(index)"),
      profile: profile,
      revision: MoriTestFixtures.revision(UInt64(index + 1)),
      tier: .standard
    )
    #expect(state.coinLedger.apply(transaction, in: profile) == .applied)
  }
  #expect(state.coinLedger.balance == 8)
  return state
}

private func purchaseAttempt(
  id: String,
  device: String,
  revision counter: UInt64,
  item: CosmeticCatalogItem,
  profile: RuntimeProfile
) -> PurchaseAttempt {
  let revision = MoriTestFixtures.revision(counter, device: device)
  let transaction = CoinTransaction(
    header: MoriTestFixtures.header(
      CoinTransactionID("buy-\(item.id.rawValue)-\(id)"),
      profile: profile
    ),
    revision: revision,
    authoredAt: MoriTestFixtures.now,
    direction: .debit,
    amount: item.coinPrice,
    reason: .cosmeticPurchase(item.id)
  )
  let ownership = CollectionOwnershipRecord(
    header: MoriTestFixtures.header(
      CollectionOwnershipID("own-\(item.id.rawValue)-\(id)"),
      profile: profile
    ),
    cosmeticID: item.id,
    slot: item.slot,
    acquiredAt: MoriTestFixtures.now,
    purchaseTransactionID: transaction.header.recordID,
    revision: revision
  )
  return PurchaseAttempt(ownership: ownership, transaction: transaction)
}

private func cosmeticDebits(
  in state: ProfileState,
  for cosmeticID: CosmeticID
) -> [CoinTransaction] {
  state.coinLedger.transactions.filter {
    guard case .cosmeticPurchase(cosmeticID) = $0.reason else { return false }
    return true
  }
}
