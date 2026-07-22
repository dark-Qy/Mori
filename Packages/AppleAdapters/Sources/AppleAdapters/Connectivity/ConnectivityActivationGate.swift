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

  func wait(startActivation: @escaping @Sendable () -> Void) async
    -> ConnectivityActivationState
  {
    let waiterID = UUID()
    return await withCheckedContinuation { continuation in
      let shouldStart = lock.withLock {
        let isFirst = waiters.isEmpty
        waiters[waiterID] = continuation
        return isFirst
      }
      if shouldStart { startActivation() }
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
