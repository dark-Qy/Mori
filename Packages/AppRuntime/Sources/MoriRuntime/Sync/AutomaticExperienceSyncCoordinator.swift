import Foundation
import MoriDomain

public protocol ExperienceSyncTransportProvider: Sendable {
  associatedtype Transport: ExperienceSyncTransport

  func transport() async throws -> Transport
}

public struct FixedExperienceSyncTransportProvider<Transport: ExperienceSyncTransport>:
  ExperienceSyncTransportProvider
{
  private let value: Transport

  public init(_ transport: Transport) {
    value = transport
  }

  public func transport() -> Transport {
    value
  }
}

public enum AutomaticExperienceSyncTrigger: String, Codable, Sendable {
  case applicationForeground
  case connectivityReachable
  case backgroundRefresh
}

public struct AutomaticExperienceSyncStatus: Codable, Equatable, Sendable {
  public let isSynchronizing: Bool
  public let hasPendingRetry: Bool
  public let completedTransferCount: UInt64
  public let acceptedEventCount: UInt64
  public let failureCount: UInt64
  public let coalescedTriggerCount: UInt64
  public let lastTrigger: AutomaticExperienceSyncTrigger?

  public init(
    isSynchronizing: Bool,
    hasPendingRetry: Bool,
    completedTransferCount: UInt64,
    acceptedEventCount: UInt64,
    failureCount: UInt64,
    coalescedTriggerCount: UInt64,
    lastTrigger: AutomaticExperienceSyncTrigger?
  ) {
    self.isSynchronizing = isSynchronizing
    self.hasPendingRetry = hasPendingRetry
    self.completedTransferCount = completedTransferCount
    self.acceptedEventCount = acceptedEventCount
    self.failureCount = failureCount
    self.coalescedTriggerCount = coalescedTriggerCount
    self.lastTrigger = lastTrigger
  }
}

/// Executable sync ownership for app lifecycle adapters.
///
/// The only public mutation entry points correspond to system lifecycle
/// signals. Product UI receives no "sync now" operation. Concurrent signals
/// coalesce behind one drain; an offline failure leaves the runtime outbox
/// untouched and the next lifecycle signal retries it.
public actor AutomaticExperienceSyncCoordinator<
  Storage: ExperienceSyncOutboxStorage,
  Ledger: ExperienceSyncLedger,
  Provider: ExperienceSyncTransportProvider
> {
  private let runtime: ExperienceSyncRuntime<Storage, Ledger>
  private let transportProvider: Provider
  private let transferLimit: Int

  private var isSynchronizing = false
  private var runAgain = false
  private var hasPendingRetry = false
  private var completedTransferCount: UInt64 = 0
  private var acceptedEventCount: UInt64 = 0
  private var failureCount: UInt64 = 0
  private var coalescedTriggerCount: UInt64 = 0
  private var lastTrigger: AutomaticExperienceSyncTrigger?

  public init(
    runtime: ExperienceSyncRuntime<Storage, Ledger>,
    transportProvider: Provider,
    transferLimit: Int = 64
  ) {
    self.runtime = runtime
    self.transportProvider = transportProvider
    self.transferLimit = max(1, transferLimit)
  }

  public func applicationDidEnterForeground() async {
    await receive(.applicationForeground)
  }

  public func connectivityDidBecomeReachable() async {
    await receive(.connectivityReachable)
  }

  public func performBackgroundRefresh() async {
    await receive(.backgroundRefresh)
  }

  public func status() -> AutomaticExperienceSyncStatus {
    AutomaticExperienceSyncStatus(
      isSynchronizing: isSynchronizing,
      hasPendingRetry: hasPendingRetry,
      completedTransferCount: completedTransferCount,
      acceptedEventCount: acceptedEventCount,
      failureCount: failureCount,
      coalescedTriggerCount: coalescedTriggerCount,
      lastTrigger: lastTrigger
    )
  }

  private func receive(_ trigger: AutomaticExperienceSyncTrigger) async {
    lastTrigger = trigger
    guard isSynchronizing == false else {
      runAgain = true
      coalescedTriggerCount &+= 1
      return
    }

    isSynchronizing = true
    defer {
      isSynchronizing = false
      runAgain = false
    }

    while true {
      runAgain = false
      do {
        let transport = try await transportProvider.transport()
        let result = try await runtime.synchronize(
          using: transport,
          limit: transferLimit
        )
        hasPendingRetry = false
        switch result {
        case .idle:
          if runAgain { continue }
          return
        case .synchronized(let eventCount):
          completedTransferCount &+= 1
          acceptedEventCount &+= UInt64(max(0, eventCount))
          // Continue until every bounded outbox batch is drained. A trigger
          // arriving during this await is already represented by `runAgain`.
          continue
        }
      } catch {
        failureCount &+= 1
        hasPendingRetry = true
        if runAgain {
          // Exactly one retry is justified by a lifecycle signal that arrived
          // after this attempt began. `runAgain` is cleared at the top of the
          // loop, so another failure cannot hot-loop without another signal.
          continue
        }
        // Do not hot-loop on a failing transport. A later lifecycle or
        // connectivity signal re-enters this drain with the durable outbox.
        return
      }
    }
  }
}
