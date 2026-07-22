import Foundation

public actor MockCompanionStateSyncClient: CompanionStateSyncClient {
  private var state: ConnectivityActivationState
  private var latest: CompanionSyncState?
  public private(set) var sentStates: [CompanionSyncState] = []
  public private(set) var activationCount = 0

  public init(
    state: ConnectivityActivationState = .inactive,
    latestReceived: CompanionSyncState? = nil
  ) {
    self.state = state
    latest = latestReceived
  }

  public func activationState() -> ConnectivityActivationState { state }

  public func activate() -> ConnectivityActivationState {
    guard state == .inactive else { return state }
    activationCount += 1
    state = .activated
    return state
  }

  public func send(_ newState: CompanionSyncState) throws {
    guard state == .activated else {
      throw ConnectivityAdapterError.unavailable("Connectivity is not activated")
    }
    if let latestSent = sentStates.last, newState.revision <= latestSent.revision {
      throw ConnectivityAdapterError.staleRevision(
        current: latestSent.revision,
        attempted: newState.revision
      )
    }
    sentStates.append(newState)
  }

  public func latestReceivedState() -> CompanionSyncState? { latest }

  public func receive(_ newState: CompanionSyncState) {
    guard latest.map({ newState.revision > $0.revision }) ?? true else { return }
    latest = newState
  }
}
