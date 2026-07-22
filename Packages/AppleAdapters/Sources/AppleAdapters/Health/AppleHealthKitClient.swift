#if canImport(HealthKit) && (os(iOS) || os(watchOS))
  @preconcurrency import HealthKit
  import Foundation

  public actor AppleHealthKitClient: HealthDataClient {
    private let store: HKHealthStore
    private var requestState: HealthAccessRequestState = .notRequested

    public init() { store = HKHealthStore() }

    public func accessRequestState() -> HealthAccessRequestState {
      guard HKHealthStore.isHealthDataAvailable() else {
        return .unavailable(reason: "Health data is unavailable on this device")
      }
      return requestState
    }

    public func requestAccess() async -> HealthAccessRequestState {
      guard HKHealthStore.isHealthDataAvailable() else {
        return .unavailable(reason: "Health data is unavailable on this device")
      }
      guard requestState == .notRequested else { return requestState }

      let readTypes = Self.readTypes
      do {
        try await store.requestAuthorization(toShare: [], read: readTypes)
        // Success only means the request flow completed. It does not reveal per-type read grants.
        requestState = .requestCompleted
      } catch {
        requestState = .unavailable(reason: error.localizedDescription)
      }
      return requestState
    }

    public func fetchSnapshot(in window: HealthQueryWindow) async throws -> HealthSnapshot {
      guard window.isValid else { throw HealthAdapterError.invalidQueryWindow }
      let predicate = HKQuery.predicateForSamples(
        withStart: window.start,
        end: window.end,
        options: .strictStartDate
      )

      let sleep = try await fetchSleep(predicate: predicate)
      let steps = try await fetchQuantities(
        identifier: .stepCount,
        unit: .count(),
        predicate: predicate
      )
      let restingHeartRate = try await fetchQuantities(
        identifier: .restingHeartRate,
        unit: HKUnit.count().unitDivided(by: .minute()),
        predicate: predicate
      )
      let workouts = try await fetchWorkouts(predicate: predicate)

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
