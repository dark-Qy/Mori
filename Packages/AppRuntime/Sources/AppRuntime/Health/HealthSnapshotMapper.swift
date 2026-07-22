import AppleAdapters
import Domain
import Foundation

public struct HealthSnapshotMapper: Sendable {
  public init() {}

  public func map(
    _ source: AppleAdapters.HealthSnapshot,
    requestState: HealthAccessRequestState,
    timeZone: TimeZone
  ) -> Domain.HealthSnapshot {
    let allSleepSamples = canonicalSleepSamples(source.sleep.values)
    let asleepSamples = allSleepSamples.filter { sample in
      switch sample.stage {
      case .core, .deep, .rem, .asleepUnspecified: true
      case .awake, .inBed: false
      }
    }
    let stages = makeStages(from: asleepSamples, allSamples: allSleepSamples)
    let sources = makeSources(from: source)
    let workouts = source.workouts.values.map { workout in
      WorkoutSummary(
        id: workout.id,
        activity: map(workout.activity),
        startedAt: workout.start,
        durationMinutes: Int(workout.durationSeconds / 60),
        activeEnergyKilocalories: workout.energyKilocalories
      )
    }

    let latestSampleDate =
      (allSleepSamples.map(\.end)
      + source.steps.values.map(\.end)
      + source.restingHeartRate.values.map(\.end)
      + source.workouts.values.map(\.end)).max()
    let capturedAt = latestSampleDate ?? source.capturedAt
    let availability = overallAvailability(source)
    let freshness: HealthDataFreshness
    if availability == .noData {
      freshness = .noData
    } else if source.capturedAt.timeIntervalSince(capturedAt) > 36 * 60 * 60 {
      freshness = .stale
    } else {
      freshness = .fresh
    }

    return Domain.HealthSnapshot(
      capturedAt: capturedAt,
      timeZoneIdentifier: timeZone.identifier,
      freshness: freshness,
      requestState: map(requestState),
      availability: availability,
      sources: sources,
      sleepMinutes: asleepSamples.isEmpty ? nil : stages.asleepMinutes,
      sleepStages: asleepSamples.isEmpty ? nil : stages,
      sleepWindowStart: asleepSamples.map(\.start).min(),
      sleepWindowEnd: asleepSamples.map(\.end).max(),
      steps: valueSum(source.steps),
      activeMinutes: workouts.isEmpty
        ? nil : workouts.reduce(0) { $0 + $1.durationMinutes },
      restingHeartRateBPM: source.restingHeartRate.values.max { $0.end < $1.end }?.value,
      workouts: workouts
    )
  }

  private func canonicalSleepSamples(_ samples: [SleepSample]) -> [SleepSample] {
    var byIdentity: [String: SleepSample] = [:]
    for sample in samples {
      let key = [
        String(sample.start.timeIntervalSince1970),
        String(sample.end.timeIntervalSince1970),
        sample.stage.rawValue,
      ].joined(separator: "|")
      if byIdentity[key] == nil { byIdentity[key] = sample }
    }
    return byIdentity.values.sorted { lhs, rhs in
      if lhs.start != rhs.start { return lhs.start < rhs.start }
      return lhs.end < rhs.end
    }
  }

  private func makeStages(
    from asleepSamples: [SleepSample],
    allSamples: [SleepSample]
  ) -> SleepStageSummary {
    func minutes(_ samples: [SleepSample]) -> Int {
      samples.reduce(0) { result, sample in
        result + max(0, Int(sample.end.timeIntervalSince(sample.start) / 60))
      }
    }
    return SleepStageSummary(
      coreMinutes: minutes(asleepSamples.filter { $0.stage == .core }),
      deepMinutes: minutes(asleepSamples.filter { $0.stage == .deep }),
      remMinutes: minutes(asleepSamples.filter { $0.stage == .rem }),
      unspecifiedMinutes: minutes(asleepSamples.filter { $0.stage == .asleepUnspecified }),
      awakeMinutes: minutes(allSamples.filter { $0.stage == .awake })
    )
  }

  private func makeSources(from snapshot: AppleAdapters.HealthSnapshot) -> [HealthSource] {
    let origins =
      snapshot.sleep.values.compactMap(\.source)
      + snapshot.steps.values.compactMap(\.source)
      + snapshot.restingHeartRate.values.compactMap(\.source)
      + snapshot.workouts.values.compactMap(\.source)
    return Set(origins).sorted { $0.bundleIdentifier < $1.bundleIdentifier }.map { source in
      HealthSource(
        identifier: source.bundleIdentifier,
        displayName: source.displayName,
        kind: sourceKind(source)
      )
    }
  }

  private func sourceKind(_ source: HealthSampleSource) -> HealthSourceKind {
    let description = "\(source.displayName) \(source.productType ?? "")".lowercased()
    if description.contains("watch") { return .appleWatch }
    if description.contains("iphone") { return .iPhone }
    if source.bundleIdentifier.hasPrefix("com.apple.") { return .unknown }
    return .thirdParty
  }

  private func valueSum(_ reading: HealthReading<[TimedQuantity]>) -> Int? {
    guard reading.availability == .available, !reading.values.isEmpty else { return nil }
    return max(0, Int(reading.values.reduce(0) { $0 + $1.value }.rounded()))
  }

  private func overallAvailability(
    _ snapshot: AppleAdapters.HealthSnapshot
  ) -> Domain.HealthDataAvailability {
    let states = [
      snapshot.sleep.availability,
      snapshot.steps.availability,
      snapshot.restingHeartRate.availability,
      snapshot.workouts.availability,
    ]
    let availableCount = states.filter { $0 == .available }.count
    if availableCount == states.count { return .available }
    if availableCount > 0 { return .partial }
    return .noData
  }

  private func map(_ state: HealthAccessRequestState) -> HealthRequestState {
    switch state {
    case .notRequested: .notRequested
    case .requestCompleted: .requestCompleted
    case .unavailable: .unavailable
    }
  }

  private func map(_ activity: WorkoutActivity) -> WorkoutSummary.Activity {
    switch activity {
    case .soccer: .soccer
    case .walking: .walking
    case .running: .running
    case .cycling: .cycling
    case .other: .other
    }
  }
}
