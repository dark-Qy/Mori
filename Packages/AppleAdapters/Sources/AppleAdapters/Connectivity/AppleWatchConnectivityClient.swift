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
    private var observers: [UUID: AsyncStream<CompanionSyncState>.Continuation] = [:]
    private let activationGate: ConnectivityActivationGate

    public override convenience init() { self.init(session: .default) }

    init(
      session: WCSession,
      activationTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
      self.session = session
      activationGate = ConnectivityActivationGate(
        timeoutNanoseconds: activationTimeoutNanoseconds
      )
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
      return await activationGate.wait(
        currentState: { [weak self] in
          guard let self else {
            return .unavailable(reason: "WatchConnectivity client was released")
          }
          return Self.map(self.session.activationState)
        },
        startActivation: { [weak self] in
          self?.session.activate()
        }
      )
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
      activationGate.resolve(result)
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
