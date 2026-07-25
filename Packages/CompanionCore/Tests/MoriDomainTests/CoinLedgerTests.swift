import Foundation
import Testing

@testable import MoriDomain

@Suite("Coin ledger invariants")
struct CoinLedgerTests {
  @Test("Mock welcome grant is fixed, unique, and non-reversible")
  func mockWelcomeGrant() {
    let profile = MoriTestFixtures.mockProfile("normal-day")
    var ledger = MoriTestFixtures.state(profile: profile).coinLedger
    let grant = CoinTransaction(
      header: MoriTestFixtures.header(
        CoinTransactionID("welcome-v1"),
        profile: profile
      ),
      revision: MoriTestFixtures.revision(1),
      authoredAt: MoriTestFixtures.now,
      direction: .credit,
      amount: 18,
      reason: .welcomeGrant(schemaVersion: 1)
    )
    let duplicateSchema = CoinTransaction(
      header: MoriTestFixtures.header(
        CoinTransactionID("welcome-v1-again"),
        profile: profile
      ),
      revision: MoriTestFixtures.revision(2),
      authoredAt: MoriTestFixtures.now,
      direction: .credit,
      amount: 18,
      reason: .welcomeGrant(schemaVersion: 1)
    )
    let reversal = CoinTransaction(
      header: MoriTestFixtures.header(
        CoinTransactionID("reverse-welcome"),
        profile: profile
      ),
      revision: MoriTestFixtures.revision(3),
      authoredAt: MoriTestFixtures.now,
      direction: .debit,
      amount: 18,
      reason: .reversal(grant.header.recordID)
    )

    #expect(ledger.apply(grant, in: profile) == .applied)
    #expect(ledger.apply(grant, in: profile) == .duplicate)
    #expect(
      ledger.apply(duplicateSchema, in: profile)
        == .rejected(.conflictingDuplicate)
    )
    #expect(
      ledger.apply(reversal, in: profile)
        == .rejected(.invalidRecord)
    )
    #expect(ledger.balance == 18)
  }

  @Test("Real profiles reject the Mock welcome grant")
  func realProfileRejectsWelcomeGrant() {
    let profile = MoriTestFixtures.profile("real-welcome")
    let grant = CoinTransaction(
      header: MoriTestFixtures.header(
        CoinTransactionID("welcome-v1"),
        profile: profile
      ),
      revision: MoriTestFixtures.revision(1),
      authoredAt: MoriTestFixtures.now,
      direction: .credit,
      amount: 18,
      reason: .welcomeGrant(schemaVersion: 1)
    )

    #expect(grant.validate(in: profile) == .invalidRecord)
  }

  @Test("Reward tiers use one coin as the minimum unit")
  func exactRewardTiers() {
    #expect(CoinRewardTier.allCases.map(\.rawValue) == [1, 2, 4, 6, 7, 8, 9, 10])
    #expect(CoinRewardTier(rawValue: 3) == nil)
    #expect(CoinRewardTier(rawValue: 5) == nil)
  }

  @Test("There is no daily reward cap")
  func noDailyCap() {
    let profile = MoriTestFixtures.profile()
    var ledger = CoinLedger(
      header: MoriTestFixtures.header(CoinLedgerID("coins"), profile: profile)
    )

    for index in 0..<500 {
      let reward = MoriTestFixtures.reward(
        "reward-\(index)",
        settlementID: TaskSettlementID("settlement-\(index)"),
        profile: profile,
        revision: MoriTestFixtures.revision(UInt64(index + 1)),
        tier: .smallest
      )
      #expect(ledger.apply(reward, in: profile) == .applied)
    }
    #expect(ledger.balance == 500)
    #expect(ledger.transactions.count == 500)
  }

  @Test("Debits never make the balance negative")
  func nonnegativeBalance() {
    let profile = MoriTestFixtures.profile()
    var ledger = CoinLedger(
      header: MoriTestFixtures.header(CoinLedgerID("coins"), profile: profile)
    )
    let debit = CoinTransaction(
      header: MoriTestFixtures.header(CoinTransactionID("debit"), profile: profile),
      revision: MoriTestFixtures.revision(1),
      authoredAt: MoriTestFixtures.now,
      direction: .debit,
      amount: 1,
      reason: .cosmeticPurchase(CosmeticID("scarf"))
    )

    #expect(ledger.apply(debit, in: profile) == .rejected(.insufficientCoins))
    #expect(ledger.balance == 0)
    #expect(ledger.transactions.isEmpty)
  }

  @Test("A transaction can be reversed exactly once")
  func reversal() {
    let profile = MoriTestFixtures.profile()
    var ledger = CoinLedger(
      header: MoriTestFixtures.header(CoinLedgerID("coins"), profile: profile)
    )
    let credit = MoriTestFixtures.reward(
      "credit",
      settlementID: TaskSettlementID("settlement"),
      profile: profile,
      revision: MoriTestFixtures.revision(1),
      tier: .meaningful
    )
    let reversal = CoinTransaction(
      header: MoriTestFixtures.header(CoinTransactionID("reversal"), profile: profile),
      revision: MoriTestFixtures.revision(2),
      authoredAt: MoriTestFixtures.now,
      direction: .debit,
      amount: 4,
      reason: .reversal(credit.header.recordID)
    )
    let secondReversal = CoinTransaction(
      header: MoriTestFixtures.header(CoinTransactionID("second-reversal"), profile: profile),
      revision: MoriTestFixtures.revision(3),
      authoredAt: MoriTestFixtures.now,
      direction: .debit,
      amount: 4,
      reason: .reversal(credit.header.recordID)
    )

    #expect(ledger.apply(reversal, in: profile) == .rejected(.invalidRecord))
    #expect(ledger.apply(credit, in: profile) == .applied)
    #expect(ledger.apply(reversal, in: profile) == .applied)
    #expect(ledger.apply(reversal, in: profile) == .duplicate)
    #expect(ledger.apply(secondReversal, in: profile) == .rejected(.invalidRecord))
    #expect(ledger.balance == 0)
  }

  @Test("Independent concurrent credits converge to canonical logical order")
  func concurrentOrder() {
    let profile = MoriTestFixtures.profile()
    let transactions = (0..<20).map { index in
      MoriTestFixtures.reward(
        "reward-\(index)",
        settlementID: TaskSettlementID("settlement-\(index)"),
        profile: profile,
        revision: MoriTestFixtures.revision(
          UInt64(index % 4 + 1),
          device: index.isMultiple(of: 2) ? "watch" : "iphone"
        ),
        tier: CoinRewardTier.allCases[index % CoinRewardTier.allCases.count]
      )
    }
    var forward = CoinLedger(
      header: MoriTestFixtures.header(CoinLedgerID("coins"), profile: profile)
    )
    var reverse = forward

    for transaction in transactions {
      #expect(forward.apply(transaction, in: profile) == .applied)
    }
    for transaction in transactions.reversed() {
      #expect(reverse.apply(transaction, in: profile) == .applied)
    }

    #expect(forward == reverse)
    #expect(forward.balance == transactions.reduce(0) { $0 + $1.amount })
  }

  @Test("A reward rejects arbitrary amounts even when divisible by the minimum unit")
  func rewardTierValidation() {
    let profile = MoriTestFixtures.profile()
    let invalid = CoinTransaction(
      header: MoriTestFixtures.header(CoinTransactionID("invalid-reward"), profile: profile),
      revision: MoriTestFixtures.revision(1),
      authoredAt: MoriTestFixtures.now,
      direction: .credit,
      amount: 5,
      reason: .taskReward(TaskSettlementID("settlement"))
    )
    #expect(invalid.validate(in: profile) == .invalidRewardTier)
  }

  @Test("Late arrival cannot rewrite canonical order into a negative prefix")
  func lateCanonicalDebitAndReversalFailClosed() {
    let profile = MoriTestFixtures.profile("canonical-prefix")
    var ledger = MoriTestFixtures.state(profile: profile).coinLedger
    let credit = CoinTransaction(
      header: MoriTestFixtures.header(CoinTransactionID("credit"), profile: profile),
      revision: MoriTestFixtures.revision(20),
      authoredAt: MoriTestFixtures.now,
      direction: .credit,
      amount: 4,
      reason: .taskReward(TaskSettlementID("canonical-prefix-reward"))
    )
    #expect(ledger.apply(credit, in: profile) == .applied)
    let accepted = ledger

    let earlierDebit = CoinTransaction(
      header: MoriTestFixtures.header(
        CoinTransactionID("earlier-debit"),
        profile: profile
      ),
      revision: MoriTestFixtures.revision(10),
      authoredAt: MoriTestFixtures.now,
      direction: .debit,
      amount: 4,
      reason: .cosmeticPurchase(CosmeticID("raincoat"))
    )
    #expect(
      ledger.apply(earlierDebit, in: profile)
        == .rejected(.insufficientCoins)
    )
    #expect(ledger == accepted)

    let earlierReversal = CoinTransaction(
      header: MoriTestFixtures.header(
        CoinTransactionID("earlier-reversal"),
        profile: profile
      ),
      revision: MoriTestFixtures.revision(5),
      authoredAt: MoriTestFixtures.now,
      direction: .debit,
      amount: credit.amount,
      reason: .reversal(credit.header.recordID)
    )
    #expect(
      ledger.apply(earlierReversal, in: profile)
        == .rejected(.invalidRecord)
    )
    #expect(ledger == accepted)
  }

  @Test("Cosmetic purchases and reversals cannot be reversed independently")
  func nonReversibleAtomicReasons() {
    let profile = MoriTestFixtures.profile("non-reversible")
    var ledger = MoriTestFixtures.state(profile: profile).coinLedger
    let funding = MoriTestFixtures.reward(
      "funding",
      settlementID: TaskSettlementID("funding-settlement"),
      profile: profile,
      revision: MoriTestFixtures.revision(1),
      tier: .rare10
    )
    let purchase = CoinTransaction(
      header: MoriTestFixtures.header(
        CoinTransactionID("purchase"),
        profile: profile
      ),
      revision: MoriTestFixtures.revision(2),
      authoredAt: MoriTestFixtures.now,
      direction: .debit,
      amount: 4,
      reason: .cosmeticPurchase(CosmeticID("raincoat"))
    )
    let reversibleReward = MoriTestFixtures.reward(
      "reversible-reward",
      settlementID: TaskSettlementID("reversible-settlement"),
      profile: profile,
      revision: MoriTestFixtures.revision(3),
      tier: .meaningful
    )
    let purchaseReversal = CoinTransaction(
      header: MoriTestFixtures.header(
        CoinTransactionID("purchase-reversal"),
        profile: profile
      ),
      revision: MoriTestFixtures.revision(4),
      authoredAt: MoriTestFixtures.now,
      direction: .credit,
      amount: 4,
      reason: .reversal(purchase.header.recordID)
    )
    let rewardReversal = CoinTransaction(
      header: MoriTestFixtures.header(
        CoinTransactionID("reward-reversal"),
        profile: profile
      ),
      revision: MoriTestFixtures.revision(5),
      authoredAt: MoriTestFixtures.now,
      direction: .debit,
      amount: 4,
      reason: .reversal(reversibleReward.header.recordID)
    )
    let chainedReversal = CoinTransaction(
      header: MoriTestFixtures.header(
        CoinTransactionID("chained-reversal"),
        profile: profile
      ),
      revision: MoriTestFixtures.revision(6),
      authoredAt: MoriTestFixtures.now,
      direction: .credit,
      amount: 4,
      reason: .reversal(rewardReversal.header.recordID)
    )

    #expect(ledger.apply(funding, in: profile) == .applied)
    #expect(ledger.apply(purchase, in: profile) == .applied)
    #expect(ledger.apply(reversibleReward, in: profile) == .applied)
    #expect(ledger.apply(purchaseReversal, in: profile) == .rejected(.invalidRecord))
    #expect(ledger.apply(rewardReversal, in: profile) == .applied)
    #expect(ledger.apply(chainedReversal, in: profile) == .rejected(.invalidRecord))
    #expect(ledger.validate(in: profile) == nil)
  }
}
