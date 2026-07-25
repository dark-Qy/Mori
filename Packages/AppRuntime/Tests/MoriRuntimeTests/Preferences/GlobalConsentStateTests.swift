import MoriDomain
import Testing

@testable import MoriRuntime

@Suite("Global consent authority")
struct GlobalConsentStateTests {
  @Test("Consent defaults off")
  func consentDefaultsOff() {
    let state = GlobalConsentState.disabled(
      revision: revision(1, "phone"),
      authorDevice: .phone
    )

    #expect(state.isValid)
    #expect(MoriConsentKind.allCases.allSatisfy { state[$0].enabled == false })
  }

  @Test("Watch-authored expansion fails closed")
  func watchCannotExpandConsent() {
    let current = GlobalConsentState.disabled(
      revision: revision(1, "phone"),
      authorDevice: .phone
    )
    let invalidExpansion = current.replacing(
      .dailyMemoryNotifications,
      with: MoriConsentRecord(
        enabled: true,
        disclosureVersion: 1,
        revision: revision(2, "watch"),
        authorDevice: .watch
      )
    )

    #expect(!invalidExpansion.isValid)
    #expect(
      GlobalConsentMerger.merge(current: current, incoming: invalidExpansion)
        == .rejected(.invalidIncoming)
    )
  }

  @Test("Concurrent revocation beats expansion independent of device order")
  func concurrentRevocationWins() throws {
    let enabled = enabledState(counter: 1)
    let expansion = enabled.replacing(
      .remoteChat,
      with: MoriConsentRecord(
        enabled: true,
        disclosureVersion: 1,
        revision: revision(2, "z-phone"),
        authorDevice: .phone
      )
    )
    let revocation = enabled.replacing(
      .remoteChat,
      with: MoriConsentRecord(
        enabled: false,
        disclosureVersion: 1,
        revision: revision(2, "a-watch"),
        authorDevice: .watch
      )
    )

    let first = try #require(
      GlobalConsentMerger.merge(current: expansion, incoming: revocation).value
    )
    let second = try #require(
      GlobalConsentMerger.merge(current: revocation, incoming: expansion).value
    )

    #expect(first == second)
    #expect(first.remoteChat.enabled == false)
    #expect(first.remoteChat.revision == revision(2, "a-watch"))
  }

  @Test("Exact revision reuse revokes and cannot block another field revocation")
  func exactRevisionConflictFailsClosedPerField() throws {
    let enabled = enabledState(counter: 4)
    let reusedRevisionRevocation =
      enabled
      .replacing(
        .remoteChat,
        with: MoriConsentRecord(
          enabled: false,
          disclosureVersion: 0,
          revision: enabled.remoteChat.revision,
          authorDevice: .watch
        )
      )
      .replacing(
        .dailyMemoryNotifications,
        with: MoriConsentRecord(
          enabled: false,
          disclosureVersion: 0,
          revision: revision(5, "watch"),
          authorDevice: .watch
        )
      )

    let forward = try #require(
      GlobalConsentMerger.merge(
        current: enabled,
        incoming: reusedRevisionRevocation
      ).value
    )
    let reverse = try #require(
      GlobalConsentMerger.merge(
        current: reusedRevisionRevocation,
        incoming: enabled
      ).value
    )

    #expect(forward == reverse)
    #expect(!forward.remoteChat.enabled)
    #expect(!forward.dailyMemoryNotifications.enabled)
  }

  @Test("A causally later disclosed iPhone choice can expand again")
  func laterPhoneExpansionCanWin() throws {
    let revoked = GlobalConsentState.disabled(
      revision: revision(2, "watch"),
      authorDevice: .watch
    )
    let expanded = revoked.replacing(
      .letterNotifications,
      with: MoriConsentRecord(
        enabled: true,
        disclosureVersion: 1,
        revision: revision(3, "phone"),
        authorDevice: .phone
      )
    )

    let result = try #require(
      GlobalConsentMerger.merge(current: revoked, incoming: expanded).value
    )
    #expect(result.letterNotifications.enabled)
  }

  @Test("Older offline values cannot undo a newer consent decision")
  func staleConsentLoses() throws {
    let newer = enabledState(counter: 4)
    let older = GlobalConsentState.disabled(
      revision: revision(3, "watch"),
      authorDevice: .watch
    )

    let result = try #require(
      GlobalConsentMerger.merge(current: newer, incoming: older).value
    )
    #expect(result == newer)
  }

  @Test("Restrictive merge converges across every delivery permutation")
  func consentPermutationProperty() throws {
    let baseline = GlobalConsentState.disabled(
      revision: revision(1, "phone"),
      authorDevice: .phone
    )
    let concurrentExpansion = baseline.replacing(
      .remoteChat,
      with: MoriConsentRecord(
        enabled: true,
        disclosureVersion: 1,
        revision: revision(2, "z-phone"),
        authorDevice: .phone
      )
    )
    let concurrentRevocation = baseline.replacing(
      .remoteChat,
      with: MoriConsentRecord(
        enabled: false,
        disclosureVersion: 1,
        revision: revision(2, "a-watch"),
        authorDevice: .watch
      )
    )
    let laterExpansion = baseline.replacing(
      .remoteChat,
      with: MoriConsentRecord(
        enabled: true,
        disclosureVersion: 1,
        revision: revision(3, "phone"),
        authorDevice: .phone
      )
    )

    let results = try consentPermutations([
      concurrentExpansion,
      concurrentRevocation,
      laterExpansion,
    ]).map { order in
      try order.reduce(baseline) { current, incoming in
        try #require(
          GlobalConsentMerger.merge(current: current, incoming: incoming).value
        )
      }
    }

    #expect(Set(results).count == 1)
    #expect(try #require(results.first).remoteChat.enabled)
    #expect(
      try #require(results.first).remoteChat.revision
        == revision(3, "phone")
    )
  }

  private func enabledState(counter: UInt64) -> GlobalConsentState {
    let record = MoriConsentRecord(
      enabled: true,
      disclosureVersion: 1,
      revision: revision(counter, "phone"),
      authorDevice: .phone
    )
    return GlobalConsentState(
      remoteChat: record,
      memoryContext: record,
      friendSharing: record,
      publicPetPublication: record,
      proactiveNotifications: record,
      dailyMemoryNotifications: record,
      letterNotifications: record
    )
  }

  private func revision(_ counter: UInt64, _ device: String) -> LamportRevision {
    LamportRevision(counter: counter, originDeviceID: device)
  }
}

private func consentPermutations<Value>(_ values: [Value]) -> [[Value]] {
  guard let first = values.first else { return [[]] }
  return consentPermutations(Array(values.dropFirst())).flatMap { tail in
    (0...tail.count).map { index in
      var value = tail
      value.insert(first, at: index)
      return value
    }
  }
}

extension GlobalConsentMergeResult {
  fileprivate var value: GlobalConsentState? {
    switch self {
    case .applied(let value), .duplicate(let value):
      value
    case .rejected:
      nil
    }
  }
}
