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

    public override convenience init() { self.init(session: .default) }

    init(session: WCSession) {
      self.session = session
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
      session.activate()
      return Self.map(session.activationState)
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
      lock.withLock { latest }
    }

    public func session(
      _ session: WCSession,
      activationDidCompleteWith activationState: WCSessionActivationState,
      error: (any Error)?
    ) {}

    public func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
      guard
        let data = context["companionState"] as? Data,
        let received = try? JSONDecoder().decode(CompanionSyncState.self, from: data)
      else { return }
      lock.withLock {
        if latest.map({ received.revision > $0.revision }) ?? true { latest = received }
      }
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
  }
#endif
