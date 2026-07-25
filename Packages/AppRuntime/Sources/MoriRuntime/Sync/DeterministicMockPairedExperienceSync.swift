#if DEBUG
  import Foundation

  public enum MockExperienceSyncEndpoint: String, Codable, Sendable {
    case iPhone
    case watch

    fileprivate var peer: Self {
      switch self {
      case .iPhone: .watch
      case .watch: .iPhone
      }
    }
  }

  public enum MockExperienceSyncLinkError: Error, Equatable, Sendable {
    case offline
    case endpointNotAttached(MockExperienceSyncEndpoint)
  }

  public struct DeterministicMockExperienceSyncTransport: ExperienceSyncTransport {
    private let link: DeterministicMockPairedExperienceSyncLink
    private let endpoint: MockExperienceSyncEndpoint

    fileprivate init(
      link: DeterministicMockPairedExperienceSyncLink,
      endpoint: MockExperienceSyncEndpoint
    ) {
      self.link = link
      self.endpoint = endpoint
    }

    public func exchange(_ transferData: Data) async throws -> Data {
      try await link.exchange(from: endpoint, transferData: transferData)
    }
  }

  public struct DeterministicMockExperienceSyncTransportProvider:
    ExperienceSyncTransportProvider
  {
    private let link: DeterministicMockPairedExperienceSyncLink
    private let endpoint: MockExperienceSyncEndpoint

    public init(
      link: DeterministicMockPairedExperienceSyncLink,
      endpoint: MockExperienceSyncEndpoint
    ) {
      self.link = link
      self.endpoint = endpoint
    }

    public func transport() -> DeterministicMockExperienceSyncTransport {
      DeterministicMockExperienceSyncTransport(
        link: link,
        endpoint: endpoint
      )
    }
  }

  /// Runnable local paired link for the current deterministic Mock profile.
  ///
  /// It connects two real `ExperienceSyncRuntime` actors and exercises their
  /// production envelope/outbox/merge path without constructing
  /// WatchConnectivity or any other production adapter.
  public actor DeterministicMockPairedExperienceSyncLink {
    private typealias Receiver = @Sendable (Data) async throws -> Data

    private var receivers: [MockExperienceSyncEndpoint: Receiver] = [:]
    private var isReachable = true
    private var exchangeCount: UInt64 = 0

    private var shouldPauseNextExchange = false
    private var exchangeIsPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var exchangeContinuation: CheckedContinuation<Void, Never>?

    public init() {}

    public func attach<
      Storage: ExperienceSyncOutboxStorage,
      Ledger: ExperienceSyncLedger
    >(
      _ runtime: ExperienceSyncRuntime<Storage, Ledger>,
      as endpoint: MockExperienceSyncEndpoint
    ) {
      receivers[endpoint] = { data in
        try await runtime.receive(data)
      }
    }

    public func setReachable(_ reachable: Bool) {
      isReachable = reachable
    }

    public func completedExchangeCount() -> UInt64 {
      exchangeCount
    }

    public func pauseNextExchange() {
      shouldPauseNextExchange = true
    }

    public func waitUntilExchangePauses() async {
      guard exchangeIsPaused == false else { return }
      await withCheckedContinuation { continuation in
        pauseWaiters.append(continuation)
      }
    }

    public func resumeExchange() {
      exchangeContinuation?.resume()
      exchangeContinuation = nil
    }

    fileprivate func exchange(
      from endpoint: MockExperienceSyncEndpoint,
      transferData: Data
    ) async throws -> Data {
      guard isReachable else {
        throw MockExperienceSyncLinkError.offline
      }
      guard let receiver = receivers[endpoint.peer] else {
        throw MockExperienceSyncLinkError.endpointNotAttached(endpoint.peer)
      }
      if shouldPauseNextExchange {
        shouldPauseNextExchange = false
        exchangeIsPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters {
          waiter.resume()
        }
        await withCheckedContinuation { continuation in
          exchangeContinuation = continuation
        }
        exchangeIsPaused = false
      }
      let response = try await receiver(transferData)
      exchangeCount &+= 1
      return response
    }
  }
#endif
