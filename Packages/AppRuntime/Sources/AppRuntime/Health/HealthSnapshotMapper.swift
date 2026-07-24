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
    let stateOfMindSamples = source.stateOfMind.values.map { sample in
      Domain.StateOfMindSample(
        id: sample.id,
        recordedAt: sample.recordedAt,
        valence: sample.valence,
        labels: Set(sample.labels.map(map))
      )
    }

    let latestSampleDate =
      (allSleepSamples.map(\.end)
      + source.steps.values.map(\.end)
      + source.restingHeartRate.values.map(\.end)
      + source.workouts.values.map(\.end)
      + source.stateOfMind.values.map(\.recordedAt)).max()
    let capturedAt =
      latestSampleDate
      ?? source.capturedAt
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
      workouts: workouts,
      stateOfMindSamples: stateOfMindSamples
    )
  }

  private func canonicalSleepSamples(_ samples: [SleepSample]) -> [SleepSample] {
    let valid = samples.filter { $0.end > $0.start }
    let boundaries = Set(valid.flatMap { [$0.start, $0.end] }).sorted()
    guard boundaries.count > 1 else { return [] }

    var result: [SleepSample] = []
    for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
      let candidates = valid.filter { sample in
        sample.start < end && sample.end > start
      }
      guard let winner = candidates.sorted(by: prefersSleepSample).first else { continue }
      result.append(
        SleepSample(start: start, end: end, stage: winner.stage, source: winner.source)
      )
    }
    return result
  }

  /// HealthKit can return overlapping intervals from several sources. Each instant must contribute
  /// to at most one stage. Awake wins to avoid claiming sleep through a reported wake interval;
  /// explicit stages win over unspecified/in-bed, then the more granular interval wins.
  private func prefersSleepSample(_ lhs: SleepSample, _ rhs: SleepSample) -> Bool {
    let lhsPriority = sleepStagePriority(lhs.stage)
    let rhsPriority = sleepStagePriority(rhs.stage)
    if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
    let lhsDuration = lhs.end.timeIntervalSince(lhs.start)
    let rhsDuration = rhs.end.timeIntervalSince(rhs.start)
    if lhsDuration != rhsDuration { return lhsDuration < rhsDuration }
    if lhs.start != rhs.start { return lhs.start > rhs.start }
    let lhsSource = lhs.source?.bundleIdentifier ?? ""
    let rhsSource = rhs.source?.bundleIdentifier ?? ""
    return lhsSource < rhsSource
  }

  private func sleepStagePriority(_ stage: AppleAdapters.SleepStage) -> Int {
    switch stage {
    case .awake: 6
    case .deep: 5
    case .rem: 4
    case .core: 3
    case .asleepUnspecified: 2
    case .inBed: 1
    }
  }

  private func makeStages(
    from asleepSamples: [SleepSample],
    allSamples: [SleepSample]
  ) -> SleepStageSummary {
    func minutes(_ samples: [SleepSample]) -> Int {
      let duration = samples.reduce(0.0) { result, sample in
        result + max(0, sample.end.timeIntervalSince(sample.start))
      }
      return Int(duration / 60)
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
      + snapshot.stateOfMind.values.compactMap(\.source)
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
    case .swimming: .swimming
    case .badminton: .badminton
    case .tennis: .tennis
    case .walking: .walking
    case .running: .running
    case .cycling: .cycling
    case .other: .other
    }
  }

  private func map(_ label: AppleAdapters.StateOfMindLabel) -> Domain.StateOfMindLabel {
    switch label {
    case .anxious: .anxious
    case .stressed: .stressed
    case .worried: .worried
    case .overwhelmed: .overwhelmed
    case .other: .other
    }
  }
}
