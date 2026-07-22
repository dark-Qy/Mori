#if canImport(HealthKit) && (os(iOS) || os(watchOS))
  @preconcurrency import HealthKit
  import Foundation

  public actor AppleHealthKitClient: HealthDataClient {
    private let store: HKHealthStore

    public init() { store = HKHealthStore() }

    public func accessRequestState() async -> HealthAccessRequestState {
      guard HKHealthStore.isHealthDataAvailable() else {
        return .unavailable(reason: "Health data is unavailable on this device")
      }
      do {
        let status = try await store.statusForAuthorizationRequest(
          toShare: [],
          read: Self.readTypes
        )
        // This reports whether the authorization sheet still needs to be shown. It deliberately
        // does not claim that any individual read type was granted.
        return switch status {
        case .shouldRequest, .unknown: .notRequested
        case .unnecessary: .requestCompleted
        @unknown default: .notRequested
        }
      } catch {
        return .unavailable(reason: error.localizedDescription)
      }
    }

    public func requestAccess() async -> HealthAccessRequestState {
      guard HKHealthStore.isHealthDataAvailable() else {
        return .unavailable(reason: "Health data is unavailable on this device")
      }
      let current = await accessRequestState()
      guard current == .notRequested else { return current }

      let readTypes = Self.readTypes
      do {
        try await store.requestAuthorization(toShare: [], read: readTypes)
        // Success only means the request flow completed. It does not reveal per-type read grants.
        return .requestCompleted
      } catch {
        return .unavailable(reason: error.localizedDescription)
      }
    }

    public func fetchSnapshot(in window: HealthQueryWindow) async throws -> HealthSnapshot {
      guard window.isValid else { throw HealthAdapterError.invalidQueryWindow }
      let dailyPredicate = HKQuery.predicateForSamples(
        withStart: window.start,
        end: window.end,
        options: .strictStartDate
      )
      let sleepPredicate = HKQuery.predicateForSamples(
        withStart: window.sleepStart,
        end: window.end,
        options: .strictStartDate
      )

      let sleep = try await fetchSleep(predicate: sleepPredicate)
      let steps = try await fetchCumulativeSum(
        identifier: .stepCount,
        unit: .count(),
        predicate: dailyPredicate,
        window: window
      )
      let restingHeartRate = try await fetchQuantities(
        identifier: .restingHeartRate,
        unit: HKUnit.count().unitDivided(by: .minute()),
        predicate: dailyPredicate
      )
      let workouts = try await fetchWorkouts(predicate: dailyPredicate)

      return HealthSnapshot(
        capturedAt: Date(),
        sleep: sleep,
        steps: steps,
        restingHeartRate: restingHeartRate,
        workouts: workouts
      )
    }

    private static var readTypes: Set<HKObjectType> {
      var types: Set<HKObjectType> = [HKObjectType.workoutType()]
      if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
        types.insert(sleep)
      }
      if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
        types.insert(steps)
      }
      if let resting = HKObjectType.quantityType(forIdentifier: .restingHeartRate) {
        types.insert(resting)
      }
      return types
    }

    private func fetchSleep(predicate: NSPredicate) async throws -> HealthReading<[SleepSample]> {
      guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
        return HealthReading(
          availability: .unavailable(reason: "Sleep analysis type is unavailable"),
          values: []
        )
      }
      let samples: [HKCategorySample] = try await fetchSamples(type: type, predicate: predicate)
      let values = samples.compactMap { sample -> SleepSample? in
        guard let stage = Self.sleepStage(for: sample.value) else { return nil }
        return SleepSample(
          start: sample.startDate,
          end: sample.endDate,
          stage: stage,
          source: Self.source(for: sample)
        )
      }
      return HealthReading(availability: values.isEmpty ? .noData : .available, values: values)
    }

    private func fetchQuantities(
      identifier: HKQuantityTypeIdentifier,
      unit: HKUnit,
      predicate: NSPredicate
    ) async throws -> HealthReading<[TimedQuantity]> {
      guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
        return HealthReading(
          availability: .unavailable(reason: "Quantity type is unavailable"),
          values: []
        )
      }
      let samples: [HKQuantitySample] = try await fetchSamples(type: type, predicate: predicate)
      let values = samples.map {
        TimedQuantity(
          start: $0.startDate,
          end: $0.endDate,
          value: $0.quantity.doubleValue(for: unit),
          source: Self.source(for: $0)
        )
      }
      return HealthReading(availability: values.isEmpty ? .noData : .available, values: values)
    }

    /// HealthKit reconciles overlapping iPhone and Watch step samples in a statistics query.
    /// Summing raw samples in the app can double-count movement recorded by both devices.
    private func fetchCumulativeSum(
      identifier: HKQuantityTypeIdentifier,
      unit: HKUnit,
      predicate: NSPredicate,
      window: HealthQueryWindow
    ) async throws -> HealthReading<[TimedQuantity]> {
      guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
        return HealthReading(
          availability: .unavailable(reason: "Quantity type is unavailable"),
          values: []
        )
      }
      return try await withCheckedThrowingContinuation { continuation in
        let query = HKStatisticsQuery(
          quantityType: type,
          quantitySamplePredicate: predicate,
          options: .cumulativeSum
        ) { _, statistics, error in
          if let error {
            continuation.resume(
              throwing: HealthAdapterError.queryFailed(error.localizedDescription)
            )
            return
          }
          guard let value = statistics?.sumQuantity()?.doubleValue(for: unit) else {
            continuation.resume(
              returning: HealthReading(availability: .noData, values: [])
            )
            return
          }
          continuation.resume(
            returning: HealthReading(
              availability: .available,
              values: [TimedQuantity(start: window.start, end: window.end, value: value)]
            )
          )
        }
        store.execute(query)
      }
    }

    private func fetchWorkouts(
      predicate: NSPredicate
    ) async throws -> HealthReading<[WorkoutSample]> {
      let samples: [HKWorkout] = try await fetchSamples(
        type: HKObjectType.workoutType(),
        predicate: predicate
      )
      let values = samples.map {
        WorkoutSample(
          id: $0.uuid,
          activity: Self.workoutActivity(for: $0.workoutActivityType),
          start: $0.startDate,
          end: $0.endDate,
          durationSeconds: $0.duration,
          energyKilocalories: $0.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
          distanceMeters: $0.totalDistance?.doubleValue(for: .meter()),
          source: Self.source(for: $0)
        )
      }
      return HealthReading(availability: values.isEmpty ? .noData : .available, values: values)
    }

    private func fetchSamples<Sample: HKSample>(
      type: HKSampleType,
      predicate: NSPredicate
    ) async throws -> [Sample] {
      try await withCheckedThrowingContinuation { continuation in
        let query = HKSampleQuery(
          sampleType: type,
          predicate: predicate,
          limit: HKObjectQueryNoLimit,
          sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { _, samples, error in
          if let error {
            continuation.resume(
              throwing: HealthAdapterError.queryFailed(error.localizedDescription)
            )
            return
          }
          continuation.resume(returning: samples as? [Sample] ?? [])
        }
        store.execute(query)
      }
    }

    private static func sleepStage(for rawValue: Int) -> SleepStage? {
      guard let value = HKCategoryValueSleepAnalysis(rawValue: rawValue) else { return nil }
      switch value {
      case .inBed: return .inBed
      case .awake: return .awake
      case .asleepUnspecified: return .asleepUnspecified
      case .asleepCore: return .core
      case .asleepDeep: return .deep
      case .asleepREM: return .rem
      @unknown default: return nil
      }
    }

    private static func workoutActivity(for type: HKWorkoutActivityType) -> WorkoutActivity {
      switch type {
      case .soccer: return .soccer
      case .walking: return .walking
      case .running: return .running
      case .cycling: return .cycling
      default: return .other
      }
    }

    private static func source(for sample: HKSample) -> HealthSampleSource {
      let revision = sample.sourceRevision
      return HealthSampleSource(
        bundleIdentifier: revision.source.bundleIdentifier,
        displayName: revision.source.name,
        productType: revision.productType
      )
    }
  }
#endif
