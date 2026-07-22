#if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
  @preconcurrency import WatchConnectivity
  import Foundation

  public final class AppleWatchConnectivityClient: NSObject, CompanionStateSyncClient,
    WCSessionDelegate, @unchecked Sendable
  {
    private let session: WCSession
    private let lock = NSLock()
    private var latest: CompanionSyncState?
    private var lastSentRevision: UInt64?
    private var activationWaiters: [UUID: CheckedContinuation<ConnectivityActivationState, Never>] =
      [:]
    private var observers: [UUID: AsyncStream<CompanionSyncState>.Continuation] = [:]
    private let activationTimeoutNanoseconds: UInt64

    public override convenience init() { self.init(session: .default) }

    init(
      session: WCSession,
      activationTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
      self.session = session
      self.activationTimeoutNanoseconds = activationTimeoutNanoseconds
      super.init()
      session.delegate = self
    }

    public func activationState() async -> ConnectivityActivationState {
      Self.map(session.activationState)
    }

    public func activate() async -> ConnectivityActivationState {
      guard WCSession.isSupported() else {
        return .unavailable(reason: "WatchConnectivity is unsupported")
      }
      let current = Self.map(session.activationState)
      guard current == .inactive else { return current }
      let waiterID = UUID()
      return await withCheckedContinuation { continuation in
        let activation = lock.withLock { () -> (shouldActivate: Bool, isWaiting: Bool) in
          let latestState = Self.map(session.activationState)
          guard latestState == .inactive else {
            continuation.resume(returning: latestState)
            return (false, false)
          }
          let shouldActivate = activationWaiters.isEmpty
          activationWaiters[waiterID] = continuation
          return (shouldActivate, true)
        }
        if activation.shouldActivate { session.activate() }
        if activation.isWaiting {
          let timeoutNanoseconds = activationTimeoutNanoseconds
          Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            self?.timeoutActivation(waiterID)
          }
        }
      }
    }

    public func send(_ state: CompanionSyncState) async throws {
      guard WCSession.isSupported() else {
        throw ConnectivityAdapterError.unavailable("WatchConnectivity is unsupported")
      }
      try lock.withLock {
        if let lastSentRevision, state.revision <= lastSentRevision {
          throw ConnectivityAdapterError.staleRevision(
            current: lastSentRevision,
            attempted: state.revision
          )
        }
        do {
          let data = try JSONEncoder().encode(state)
          try session.updateApplicationContext(["companionState": data])
          lastSentRevision = state.revision
        } catch let error as ConnectivityAdapterError {
          throw error
        } catch {
          throw ConnectivityAdapterError.transportFailed(error.localizedDescription)
        }
      }
    }

    public func latestReceivedState() async -> CompanionSyncState? {
      let result = lock.withLock {
        let update = decodeAndStore(context: session.receivedApplicationContext)
        return (latest, update)
      }
      publish(result.1)
      return result.0
    }

    public func receivedStates() async -> AsyncStream<CompanionSyncState> {
      let observerID = UUID()
      return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let current = lock.withLock { () -> CompanionSyncState? in
          observers[observerID] = continuation
          return latest
        }
        if let current { continuation.yield(current) }
        continuation.onTermination = { [weak self] _ in
          self?.removeObserver(observerID)
        }
      }
    }

    public func session(
      _ session: WCSession,
      activationDidCompleteWith activationState: WCSessionActivationState,
      error: (any Error)?
    ) {
      let result =
        error.map {
          ConnectivityActivationState.unavailable(reason: $0.localizedDescription)
        } ?? Self.map(activationState)
      let waiters = lock.withLock {
        () -> [CheckedContinuation<ConnectivityActivationState, Never>] in
        let values = Array(activationWaiters.values)
        activationWaiters.removeAll()
        return values
      }
      for waiter in waiters {
        waiter.resume(returning: result)
      }
    }

    private func timeoutActivation(_ waiterID: UUID) {
      let waiter = lock.withLock { activationWaiters.removeValue(forKey: waiterID) }
      waiter?.resume(
        returning: .unavailable(reason: "WatchConnectivity activation timed out")
      )
    }

    public func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
      let update = lock.withLock { decodeAndStore(context: context) }
      publish(update)
    }

    #if os(iOS)
      public func sessionDidBecomeInactive(_ session: WCSession) {}
      public func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif

    private static func map(_ state: WCSessionActivationState) -> ConnectivityActivationState {
      switch state {
      case .notActivated, .inactive: return .inactive
      case .activated: return .activated
      @unknown default: return .unavailable(reason: "Unknown activation state")
      }
    }

    private func decodeAndStore(context: [String: Any]) -> CompanionSyncState? {
      guard
        let data = context["companionState"] as? Data,
        let received = try? JSONDecoder().decode(CompanionSyncState.self, from: data),
        latest.map({ received.revision > $0.revision }) ?? true
      else { return nil }
      latest = received
      return received
    }

    private func publish(_ state: CompanionSyncState?) {
      guard let state else { return }
      let currentObservers = lock.withLock { Array(observers.values) }
      for observer in currentObservers {
        observer.yield(state)
      }
    }

    private func removeObserver(_ id: UUID) {
      lock.withLock { observers[id] = nil }
    }
  }
#endif
