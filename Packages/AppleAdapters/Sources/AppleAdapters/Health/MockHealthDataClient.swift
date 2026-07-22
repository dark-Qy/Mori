import Foundation

public actor MockHealthDataClient: HealthDataClient {
  private var requestState: HealthAccessRequestState
  private var snapshot: HealthSnapshot
  private var fetchError: HealthAdapterError?
  public private(set) var requestInvocationCount = 0
  public private(set) var fetchInvocationCount = 0

  public init(
    requestState: HealthAccessRequestState = .notRequested,
    snapshot: HealthSnapshot,
    fetchError: HealthAdapterError? = nil
  ) {
    self.requestState = requestState
    self.snapshot = snapshot
    self.fetchError = fetchError
  }

  public func accessRequestState() -> HealthAccessRequestState { requestState }

  public func requestAccess() -> HealthAccessRequestState {
    guard requestState == .notRequested else { return requestState }
    requestInvocationCount += 1
    requestState = .requestCompleted
    return requestState
  }

  public func fetchSnapshot(in window: HealthQueryWindow) throws -> HealthSnapshot {
    guard window.isValid else { throw HealthAdapterError.invalidQueryWindow }
    fetchInvocationCount += 1
    if let fetchError { throw fetchError }
    return snapshot
  }

  public func replaceSnapshot(_ snapshot: HealthSnapshot) { self.snapshot = snapshot }
  public func setFetchError(_ error: HealthAdapterError?) { fetchError = error }
}

public struct UnavailableHealthDataClient: HealthDataClient {
  private let reason: String

  public init(reason: String) { self.reason = reason }

  public func accessRequestState() async -> HealthAccessRequestState {
    .unavailable(reason: reason)
  }

  public func requestAccess() async -> HealthAccessRequestState {
    .unavailable(reason: reason)
  }

  public func fetchSnapshot(in window: HealthQueryWindow) async throws -> HealthSnapshot {
    guard window.isValid else { throw HealthAdapterError.invalidQueryWindow }
    let unavailable = HealthDataAvailability.unavailable(reason: reason)
    return HealthSnapshot(
      capturedAt: Date(),
      sleep: HealthReading(availability: unavailable, values: []),
      steps: HealthReading(availability: unavailable, values: []),
      restingHeartRate: HealthReading(availability: unavailable, values: []),
      workouts: HealthReading(availability: unavailable, values: [])
    )
  }
}
