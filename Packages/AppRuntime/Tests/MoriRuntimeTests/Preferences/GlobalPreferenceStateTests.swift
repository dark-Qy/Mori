import Foundation
import MoriDomain
import Testing

@testable import MoriRuntime

@Suite("Global synchronized preferences")
struct GlobalPreferenceStateTests {
  @Test("Independent registers converge regardless of arrival order")
  func independentRegistersConverge() throws {
    let baseline = try preferences(
      profileRevision: revision(1, "phone"),
      sensingRevision: revision(1, "phone"),
      reminderRevision: revision(1, "phone"),
      quietRevision: revision(1, "phone")
    )
    let phone = try preferences(
      profileRevision: revision(1, "phone"),
      sensingRevision: revision(1, "phone"),
      reminderRevision: revision(3, "phone"),
      quietRevision: revision(1, "phone"),
      reminderMode: .gentleHaptic
    )
    let watch = try preferences(
      profileRevision: revision(1, "phone"),
      sensingRevision: revision(1, "phone"),
      reminderRevision: revision(1, "phone"),
      quietRevision: revision(2, "watch"),
      quietHours: CompanionQuietHours(startMinute: 1_380, endMinute: 480)
    )

    let phoneThenWatch = try #require(
      GlobalPreferenceMerger.merge(current: baseline, incoming: phone).value
    )
    let firstResult = try #require(
      GlobalPreferenceMerger.merge(current: phoneThenWatch, incoming: watch).value
    )
    let watchThenPhone = try #require(
      GlobalPreferenceMerger.merge(current: baseline, incoming: watch).value
    )
    let secondResult = try #require(
      GlobalPreferenceMerger.merge(current: watchThenPhone, incoming: phone).value
    )

    #expect(firstResult == secondResult)
    #expect(firstResult.reminderMode.value == .gentleHaptic)
    #expect(
      firstResult.quietHours.value
        == CompanionQuietHours(startMinute: 1_380, endMinute: 480)
    )
  }

  @Test("Unrelated exact conflict cannot block a newer sensing revocation")
  func conflictingReminderCannotBlockSensingRevocation() throws {
    let current = try preferences(
      profileRevision: revision(1, "phone"),
      sensingRevision: revision(1, "phone"),
      reminderRevision: revision(2, "watch"),
      quietRevision: revision(1, "phone")
    )
    let conflictingAndRevoked = try preferences(
      profileRevision: revision(1, "phone"),
      sensingRevision: revision(3, "phone"),
      reminderRevision: revision(2, "watch"),
      quietRevision: revision(1, "phone"),
      sensingEnabled: false,
      reminderMode: .gentleHaptic
    )

    let forward = try #require(
      GlobalPreferenceMerger.merge(
        current: current,
        incoming: conflictingAndRevoked
      ).value
    )
    let reverse = try #require(
      GlobalPreferenceMerger.merge(
        current: conflictingAndRevoked,
        incoming: current
      ).value
    )

    #expect(forward == reverse)
    #expect(!forward.companionSensing.value.enabled)
    #expect(forward.companionSensing.revision == revision(3, "phone"))
  }

  @Test("Exact sensing conflict converges to disabled")
  func sensingConflictFailsClosed() throws {
    let enabled = try preferences(
      profileRevision: revision(1, "phone"),
      sensingRevision: revision(4, "watch"),
      reminderRevision: revision(1, "phone"),
      quietRevision: revision(1, "phone")
    )
    let disabled = try preferences(
      profileRevision: revision(1, "phone"),
      sensingRevision: revision(4, "watch"),
      reminderRevision: revision(1, "phone"),
      quietRevision: revision(1, "phone"),
      sensingEnabled: false
    )

    let forward = try #require(
      GlobalPreferenceMerger.merge(current: enabled, incoming: disabled).value
    )
    let reverse = try #require(
      GlobalPreferenceMerger.merge(current: disabled, incoming: enabled).value
    )

    #expect(forward == reverse)
    #expect(!forward.companionSensing.value.enabled)
    #expect(forward.companionSensing.revision == revision(4, "watch"))
  }

  @Test("Sensing authority must carry its exact Lamport epoch")
  func sensingEpochIsBoundToRevision() throws {
    let valid = try preferences(
      profileRevision: revision(1, "phone"),
      sensingRevision: revision(2, "watch"),
      reminderRevision: revision(1, "phone"),
      quietRevision: revision(1, "phone")
    )
    let invalid = GlobalSyncedPreferences(
      profileSelection: valid.profileSelection,
      companionSensing: RevisionedPreference(
        value: CompanionSensingPreference(
          enabled: true,
          epoch: SensingEpoch(revision(3, "watch"))
        ),
        revision: revision(2, "watch")
      ),
      reminderMode: valid.reminderMode,
      quietHours: valid.quietHours
    )

    #expect(valid.isValid)
    #expect(!invalid.isValid)
    #expect(
      GlobalPreferenceMerger.merge(current: valid, incoming: invalid)
        == .rejected(.invalidIncoming)
    )
  }

  @Test("Quiet hours support overnight and daytime windows")
  func quietHourWindows() {
    let overnight = CompanionQuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
    #expect(overnight.contains(minuteOfDay: 23 * 60))
    #expect(overnight.contains(minuteOfDay: 6 * 60))
    #expect(!overnight.contains(minuteOfDay: 12 * 60))

    let daytime = CompanionQuietHours(startMinute: 9 * 60, endMinute: 17 * 60)
    #expect(daytime.contains(minuteOfDay: 10 * 60))
    #expect(!daytime.contains(minuteOfDay: 18 * 60))
    #expect(!CompanionQuietHours(startMinute: 0, endMinute: 0).isValid)
  }

  @Test("Register convergence is invariant across every delivery permutation")
  func deliveryPermutationProperty() throws {
    let baseline = try preferences(
      profileRevision: revision(1, "phone"),
      sensingRevision: revision(1, "phone"),
      reminderRevision: revision(1, "phone"),
      quietRevision: revision(1, "phone")
    )
    let candidates = [
      try preferences(
        profileRevision: revision(4, "watch"),
        sensingRevision: revision(1, "phone"),
        reminderRevision: revision(1, "phone"),
        quietRevision: revision(1, "phone")
      ),
      try preferences(
        profileRevision: revision(1, "phone"),
        sensingRevision: revision(5, "phone"),
        reminderRevision: revision(1, "phone"),
        quietRevision: revision(1, "phone")
      ),
      try preferences(
        profileRevision: revision(1, "phone"),
        sensingRevision: revision(1, "phone"),
        reminderRevision: revision(6, "watch"),
        quietRevision: revision(1, "phone"),
        reminderMode: .gentleHaptic
      ),
      try preferences(
        profileRevision: revision(1, "phone"),
        sensingRevision: revision(1, "phone"),
        reminderRevision: revision(1, "phone"),
        quietRevision: revision(7, "phone"),
        quietHours: CompanionQuietHours(startMinute: 23 * 60, endMinute: 8 * 60)
      ),
    ]

    let results = try permutations(candidates).map { order in
      try order.reduce(baseline) { current, incoming in
        try #require(
          GlobalPreferenceMerger.merge(current: current, incoming: incoming).value
        )
      }
    }

    #expect(Set(results).count == 1)
    let result = try #require(results.first)
    #expect(result.profileSelection.revision == revision(4, "watch"))
    #expect(result.companionSensing.revision == revision(5, "phone"))
    #expect(result.reminderMode.value == .gentleHaptic)
    #expect(
      result.quietHours.value
        == CompanionQuietHours(startMinute: 23 * 60, endMinute: 8 * 60)
    )
  }

  @Test("Conflict plus sensing revocation converges across every permutation")
  func conflictRevocationPermutationProperty() throws {
    let baseline = try preferences(
      profileRevision: revision(1, "phone"),
      sensingRevision: revision(1, "phone"),
      reminderRevision: revision(1, "phone"),
      quietRevision: revision(1, "phone")
    )
    let reminderA = try preferences(
      profileRevision: revision(1, "phone"),
      sensingRevision: revision(1, "phone"),
      reminderRevision: revision(4, "shared"),
      quietRevision: revision(1, "phone"),
      reminderMode: .wristRaise
    )
    let reminderBAndRevocation = try preferences(
      profileRevision: revision(1, "phone"),
      sensingRevision: revision(5, "watch"),
      reminderRevision: revision(4, "shared"),
      quietRevision: revision(1, "phone"),
      sensingEnabled: false,
      reminderMode: .gentleHaptic
    )
    let quietChange = try preferences(
      profileRevision: revision(1, "phone"),
      sensingRevision: revision(1, "phone"),
      reminderRevision: revision(1, "phone"),
      quietRevision: revision(6, "phone"),
      quietHours: CompanionQuietHours(
        startMinute: 23 * 60,
        endMinute: 8 * 60
      )
    )

    let results = try permutations([
      reminderA,
      reminderBAndRevocation,
      quietChange,
    ]).map { order in
      try order.reduce(baseline) { current, incoming in
        try #require(
          GlobalPreferenceMerger.merge(current: current, incoming: incoming).value
        )
      }
    }

    #expect(Set(results).count == 1)
    let result = try #require(results.first)
    #expect(!result.companionSensing.value.enabled)
    #expect(result.companionSensing.revision == revision(5, "watch"))
    #expect(
      result.quietHours.value
        == CompanionQuietHours(
          startMinute: 23 * 60,
          endMinute: 8 * 60
        )
    )
  }

  private func preferences(
    profileRevision: LamportRevision,
    sensingRevision: LamportRevision,
    reminderRevision: LamportRevision,
    quietRevision: LamportRevision,
    sensingEnabled: Bool = true,
    reminderMode: CompanionReminderMode = .wristRaise,
    quietHours: CompanionQuietHours = CompanionQuietHours(
      startMinute: 22 * 60,
      endMinute: 7 * 60
    )
  ) throws -> GlobalSyncedPreferences {
    let profile = RuntimeProfile(
      id: ProfileID("real"),
      epoch: ProfileEpoch(revision(1, "phone")),
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("baseline"),
        revision: revision(1, "phone")
      ),
      source: .real
    )
    return GlobalSyncedPreferences(
      profileSelection: try .real(
        profile: profile,
        selectionRevision: profileRevision
      ),
      companionSensing: RevisionedPreference(
        value: CompanionSensingPreference(
          enabled: sensingEnabled,
          epoch: SensingEpoch(sensingRevision)
        ),
        revision: sensingRevision
      ),
      reminderMode: RevisionedPreference(
        value: reminderMode,
        revision: reminderRevision
      ),
      quietHours: RevisionedPreference(
        value: quietHours,
        revision: quietRevision
      )
    )
  }

  private func revision(_ counter: UInt64, _ device: String) -> LamportRevision {
    LamportRevision(counter: counter, originDeviceID: device)
  }
}

private func permutations<Value>(_ values: [Value]) -> [[Value]] {
  guard let first = values.first else { return [[]] }
  return permutations(Array(values.dropFirst())).flatMap { tail in
    (0...tail.count).map { index in
      var value = tail
      value.insert(first, at: index)
      return value
    }
  }
}

extension GlobalPreferenceMergeResult {
  fileprivate var value: GlobalSyncedPreferences? {
    switch self {
    case .applied(let value), .duplicate(let value):
      value
    case .rejected:
      nil
    }
  }
}
