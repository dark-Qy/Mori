import Foundation

/// Owns the continuation lifecycle shared by the production WatchConnectivity adapter. Keeping the
/// timeout and fan-out policy independent from `WCSession` makes the failure contract testable.
final class ConnectivityActivationGate: @unchecked Sendable {
  private let lock = NSLock()
  private let timeoutNanoseconds: UInt64
  private var waiters: [UUID: CheckedContinuation<ConnectivityActivationState, Never>] = [:]

  init(timeoutNanoseconds: UInt64) {
    self.timeoutNanoseconds = timeoutNanoseconds
  }

  func wait(
    currentState: @escaping @Sendable () -> ConnectivityActivationState,
    startActivation: @escaping @Sendable () -> Void
  ) async
    -> ConnectivityActivationState
  {
    let waiterID = UUID()
    return await withCheckedContinuation { continuation in
      let registration = lock.withLock { () -> (ConnectivityActivationState?, Bool) in
        // WCSession updates activationState before its delegate callback. Rechecking while the
        // gate is locked closes the gap between the caller's optimistic read and registration:
        // either we observe the terminal state, or resolve() observes this waiter.
        let observedState = currentState()
        guard observedState == .inactive else { return (observedState, false) }
        let isFirst = waiters.isEmpty
        waiters[waiterID] = continuation
        return (nil, isFirst)
      }
      if let observedState = registration.0 {
        continuation.resume(returning: observedState)
        return
      }
      if registration.1 { startActivation() }
      let timeout = timeoutNanoseconds
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: timeout)
        self?.timeout(waiterID)
      }
    }
  }

  func resolve(_ state: ConnectivityActivationState) {
    let pending = lock.withLock {
      let values = Array(waiters.values)
      waiters.removeAll()
      return values
    }
    for waiter in pending {
      waiter.resume(returning: state)
    }
  }

  func pendingWaiterCount() -> Int {
    lock.withLock { waiters.count }
  }

  private func timeout(_ waiterID: UUID) {
    let waiter = lock.withLock { waiters.removeValue(forKey: waiterID) }
    waiter?.resume(
      returning: .unavailable(reason: "WatchConnectivity activation timed out")
    )
  }
}
