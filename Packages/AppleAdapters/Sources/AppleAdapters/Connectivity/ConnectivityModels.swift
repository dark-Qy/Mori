import Foundation

public enum ConnectivityActivationState: Equatable, Sendable {
  case inactive
  case activated
  case unavailable(reason: String)
}

public struct CompanionSyncState: Codable, Equatable, Sendable {
  public let revision: UInt64
  public let updatedAt: Date
  public let values: [String: String]

  public init(revision: UInt64, updatedAt: Date, values: [String: String]) {
    self.revision = revision
    self.updatedAt = updatedAt
    self.values = values
  }
}

public protocol CompanionStateSyncClient: Sendable {
  func activationState() async -> ConnectivityActivationState
  func activate() async -> ConnectivityActivationState
  func send(_ state: CompanionSyncState) async throws
  func latestReceivedState() async -> CompanionSyncState?
  func receivedStates() async -> AsyncStream<CompanionSyncState>
}

public enum ConnectivityAdapterError: Error, Equatable, Sendable {
  case unavailable(String)
  case staleRevision(current: UInt64, attempted: UInt64)
  case encodingFailed
  case transportFailed(String)
}
