import AppleAdapters
import CryptoKit
import Foundation
import MoriDomain

/// The authority stamped onto a newly observed fact. A fact captured while
/// companionship is disabled remains display-only forever; re-enabling creates
/// new facts in a new sensing epoch instead of upgrading old observations.
public enum EvidenceAdmissionMode: Hashable, Sendable {
  case displayOnly
  case companion(SensingEpoch, activeSince: Date)

  fileprivate var authorization: EvidenceAuthorization {
    switch self {
    case .displayOnly:
      .displayOnly
    case .companion(let sensingEpoch, _):
      .companion(sensingEpoch)
    }
  }

  fileprivate var activeSince: Date? {
    if case .companion(_, let activeSince) = self { activeSince } else { nil }
  }
}

public struct EvidenceFreshnessPolicy: Equatable, Sendable {
  public let stepSummary: TimeInterval
  public let sleepSummary: TimeInterval
  public let broadMotion: TimeInterval
  public let approvedPlace: TimeInterval
  public let foregroundInteraction: TimeInterval

  public init(
    stepSummary: TimeInterval = 15 * 60,
    sleepSummary: TimeInterval = 24 * 60 * 60,
    broadMotion: TimeInterval = 2 * 60,
    approvedPlace: TimeInterval = 5 * 60,
    foregroundInteraction: TimeInterval = 10
  ) {
    self.stepSummary = max(0, stepSummary)
    self.sleepSummary = max(0, sleepSummary)
    self.broadMotion = max(0, broadMotion)
    self.approvedPlace = max(0, approvedPlace)
    self.foregroundInteraction = max(0, foregroundInteraction)
  }

  public static let productDefault = Self()
}

/// Privacy-minimized output of one adapter read. Raw HealthKit samples,
/// coordinates, routes, and motion samples never leave the normalizer.
public struct NormalizedEvidenceBatch: Equatable, Sendable {
  public let displayFacts: [DerivedFactRecord]
  public let companionFacts: [DerivedFactRecord]

  public init(
    displayFacts: [DerivedFactRecord],
    companionFacts: [DerivedFactRecord]
  ) {
    self.displayFacts = displayFacts
    self.companionFacts = companionFacts
  }

  public var facts: [DerivedFactRecord] { displayFacts + companionFacts }
}

public struct MoriEvidenceNormalizer: Sendable {
  private let freshness: EvidenceFreshnessPolicy

  public init(freshness: EvidenceFreshnessPolicy = .productDefault) {
    self.freshness = freshness
  }

  public func normalizeHealth(
    _ snapshot: AppleAdapters.HealthSnapshot,
    profile: RuntimeProfile,
    admission: EvidenceAdmissionMode
  ) -> NormalizedEvidenceBatch {
    guard profile.isValid else {
      return NormalizedEvidenceBatch(displayFacts: [], companionFacts: [])
    }
    var displayFacts: [DerivedFactRecord] = []
    var companionFacts: [DerivedFactRecord] = []

    if case .available = snapshot.steps.availability,
      let total = Self.safeStepTotal(snapshot.steps.values)
    {
      displayFacts.append(
        makeFact(
          profile: profile,
          observedAt: snapshot.capturedAt,
          freshness: freshness.stepSummary,
          value: .stepTotal(total),
          provenance: provenance(for: profile, real: .healthSummary),
          admission: .displayOnly
        )
      )
      if let activeSince = admission.activeSince,
        activeSince <= snapshot.capturedAt,
        let companionTotal = Self.safeStepTotal(
          snapshot.steps.values.filter {
            $0.start >= activeSince && $0.end <= snapshot.capturedAt
          }
        )
      {
        companionFacts.append(
          makeFact(
            profile: profile,
            observedAt: snapshot.capturedAt,
            freshness: freshness.stepSummary,
            value: .stepTotal(companionTotal),
            provenance: provenance(for: profile, real: .healthSummary),
            admission: admission
          )
        )
      }
    }

    if case .available = snapshot.sleep.availability,
      let duration = Self.sleepDuration(snapshot.sleep.values),
      let sleepObservedAt = Self.latestSleepEnd(snapshot.sleep.values)
    {
      displayFacts.append(
        makeFact(
          profile: profile,
          observedAt: sleepObservedAt,
          freshness: freshness.sleepSummary,
          value: .sleepDuration(duration),
          provenance: provenance(for: profile, real: .healthSummary),
          admission: .displayOnly
        )
      )
      if let activeSince = admission.activeSince,
        activeSince <= snapshot.capturedAt,
        Self.allSleepIntervals(snapshot.sleep.values, startAtOrAfter: activeSince)
      {
        companionFacts.append(
          makeFact(
            profile: profile,
            observedAt: sleepObservedAt,
            freshness: freshness.sleepSummary,
            value: .sleepDuration(duration),
            provenance: provenance(for: profile, real: .healthSummary),
            admission: admission
          )
        )
      }
    }

    return NormalizedEvidenceBatch(
      displayFacts: displayFacts,
      companionFacts: companionFacts
    )
  }

  /// Low-confidence or unknown classifications are neutral. The accepted fact
  /// is deliberately broad; classifier confidence is used only as an admission
  /// threshold and is not presented to the person.
  public func normalizeMotion(
    _ observation: BroadMotionObservation,
    profile: RuntimeProfile,
    admission: EvidenceAdmissionMode
  ) -> DerivedFactRecord? {
    guard
      profile.isValid,
      observation.confidence != .low,
      admission.admits(observedAt: observation.observedAt),
      let motion = Self.domainMotion(observation.activity)
    else {
      return nil
    }
    return makeFact(
      profile: profile,
      observedAt: observation.observedAt,
      freshness: freshness.broadMotion,
      value: .broadMotion(motion),
      provenance: provenance(for: profile, real: .motionClassifier),
      admission: admission
    )
  }

  /// Only an entry transition can support an arrival interpretation. Exit
  /// callbacks remain device-local adapter state and do not become a fact.
  public func normalizeApprovedPlace(
    _ observation: AppleAdapters.ApprovedPlaceObservation,
    profile: RuntimeProfile,
    admission: EvidenceAdmissionMode
  ) -> DerivedFactRecord? {
    guard
      profile.isValid,
      observation.presence == .entered,
      admission.admits(observedAt: observation.observedAt)
    else {
      return nil
    }
    return makeFact(
      profile: profile,
      observedAt: observation.observedAt,
      freshness: freshness.approvedPlace,
      value: .approvedPlaceCategory(Self.domainPlace(observation.category)),
      provenance: provenance(for: profile, real: .coarsePlaceClassifier),
      admission: admission
    )
  }

  public func normalizeForegroundInteraction(
    observedAt: Date,
    profile: RuntimeProfile,
    admission: EvidenceAdmissionMode
  ) -> DerivedFactRecord? {
    guard profile.isValid, admission.admits(observedAt: observedAt) else { return nil }
    return makeFact(
      profile: profile,
      observedAt: observedAt,
      freshness: freshness.foregroundInteraction,
      value: .foregroundInteraction,
      provenance: provenance(for: profile, real: .foregroundInteraction),
      admission: admission
    )
  }

  private func makeFact(
    profile: RuntimeProfile,
    observedAt: Date,
    freshness: TimeInterval,
    value: DerivedFactValue,
    provenance: EvidenceProvenance,
    admission: EvidenceAdmissionMode
  ) -> DerivedFactRecord {
    DerivedFactRecord(
      header: ProfileScopedRecordHeader(
        recordID: EvidenceID(
          Self.stableID(
            profile: profile,
            value: value,
            provenance: provenance,
            observedAt: observedAt,
            admission: admission
          )
        ),
        profileID: profile.id,
        profileEpoch: profile.epoch,
        deletionEpoch: profile.deletionEpoch
      ),
      observedAt: observedAt,
      freshUntil: observedAt.addingTimeInterval(freshness),
      value: value,
      provenance: provenance,
      authorization: admission.authorization
    )
  }

  private func provenance(
    for profile: RuntimeProfile,
    real: EvidenceProvenance
  ) -> EvidenceProvenance {
    profile.isMock ? .deterministicMock : real
  }

  private static func safeStepTotal(_ quantities: [TimedQuantity]) -> Int? {
    var total = 0.0
    for quantity in quantities {
      guard
        quantity.value.isFinite,
        quantity.value >= 0,
        quantity.start <= quantity.end
      else {
        return nil
      }
      total += quantity.value
      guard total.isFinite, total <= 10_000_000 else { return nil }
    }
    guard quantities.isEmpty == false else { return nil }
    return Int(total.rounded())
  }

  private static func sleepDuration(_ samples: [SleepSample]) -> TimeInterval? {
    let intervals = samples.compactMap { sample -> DateInterval? in
      guard
        sample.start < sample.end,
        sample.stage != .awake,
        sample.stage != .inBed
      else {
        return nil
      }
      return DateInterval(start: sample.start, end: sample.end)
    }.sorted {
      if $0.start != $1.start { return $0.start < $1.start }
      return $0.end < $1.end
    }
    guard let first = intervals.first else { return nil }

    var total: TimeInterval = 0
    var current = first
    for interval in intervals.dropFirst() {
      if interval.start <= current.end {
        current = DateInterval(
          start: current.start,
          end: max(current.end, interval.end)
        )
      } else {
        total += current.duration
        current = interval
      }
    }
    total += current.duration
    return total.isFinite && total >= 0 ? total : nil
  }

  private static func allSleepIntervals(
    _ samples: [SleepSample],
    startAtOrAfter lowerBound: Date
  ) -> Bool {
    let sleepSamples = samples.filter {
      $0.stage != .awake && $0.stage != .inBed && $0.start < $0.end
    }
    return sleepSamples.isEmpty == false
      && sleepSamples.allSatisfy { $0.start >= lowerBound }
  }

  private static func latestSleepEnd(_ samples: [SleepSample]) -> Date? {
    samples
      .filter {
        $0.stage != .awake && $0.stage != .inBed && $0.start < $0.end
      }
      .map(\.end)
      .max()
  }

  private static func domainMotion(
    _ motion: BroadMotionActivity
  ) -> MoriDomain.BroadMotion? {
    switch motion {
    case .stationary: .stationary
    case .walking: .walking
    case .running: .running
    case .cycling: .cycling
    case .automotive: .automotive
    case .unknown: nil
    }
  }

  private static func domainPlace(
    _ place: AppleAdapters.ApprovedPlaceCategory
  ) -> MoriDomain.ApprovedPlaceCategory {
    switch place {
    case .home: .home
    case .work: .work
    case .park: .park
    case .transit: .transit
    case .other: .other
    }
  }

  private static func stableID(
    profile: RuntimeProfile,
    value: DerivedFactValue,
    provenance: EvidenceProvenance,
    observedAt: Date,
    admission: EvidenceAdmissionMode
  ) -> String {
    let sourceComponents: [String] =
      switch profile.source {
      case .real:
        ["real"]
      case .mock(let scenarioID, let selectionEpoch):
        [
          "mock",
          scenarioID.rawValue,
          String(selectionEpoch.revision.counter),
          selectionEpoch.revision.originDeviceID,
        ]
      }
    let authorizationComponents: [String] =
      switch admission {
      case .displayOnly:
        ["display"]
      case .companion(let epoch, let activeSince):
        [
          "companion",
          String(epoch.revision.counter),
          epoch.revision.originDeviceID,
          dateKey(activeSince),
        ]
      }
    let input = CanonicalHashInput.data(
      [
        "mori-evidence-v2",
        profile.id.rawValue,
        String(profile.epoch.revision.counter),
        profile.epoch.revision.originDeviceID,
        profile.deletionEpoch.requestID.rawValue,
        String(profile.deletionEpoch.revision.counter),
        profile.deletionEpoch.revision.originDeviceID,
        valueKey(value),
        provenance.rawValue,
        dateKey(observedAt),
      ] + sourceComponents + authorizationComponents
    )
    let digest = SHA256.hash(data: input)
      .map { String(format: "%02x", $0) }
      .joined()
    return "evidence-\(digest)"
  }

  private static func dateKey(_ date: Date) -> String {
    String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
  }

  private static func valueKey(_ value: DerivedFactValue) -> String {
    switch value {
    case .stepTotal(let total):
      return "steps:\(total)"
    case .sleepDuration(let duration):
      return "sleep:\(String(duration.bitPattern, radix: 16))"
    case .broadMotion(let motion):
      return "motion:\(motion.rawValue)"
    case .approvedPlaceCategory(let category):
      return "place:\(category.rawValue)"
    case .foregroundInteraction:
      return "foreground"
    }
  }
}

extension EvidenceAdmissionMode {
  fileprivate func admits(observedAt: Date) -> Bool {
    switch self {
    case .displayOnly:
      true
    case .companion(_, let activeSince):
      observedAt >= activeSince
    }
  }
}
