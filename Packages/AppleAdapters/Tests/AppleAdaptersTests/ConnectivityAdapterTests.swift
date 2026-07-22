import Foundation
import Testing

@testable import AppleAdapters

@Suite("Watch connectivity boundary")
struct ConnectivityAdapterTests {
  @Test func activationIsIdempotent() async {
    let client = MockCompanionStateSyncClient()
    #expect(await client.activate() == .activated)
    #expect(await client.activate() == .activated)
    #expect(await client.activationCount == 1)
  }

  @Test func sendRejectsDuplicateAndStaleRevisions() async throws {
    let client = MockCompanionStateSyncClient(state: .activated)
    try await client.send(syncState(revision: 2))
    await #expect(throws: ConnectivityAdapterError.staleRevision(current: 2, attempted: 2)) {
      try await client.send(self.syncState(revision: 2))
    }
    await #expect(throws: ConnectivityAdapterError.staleRevision(current: 2, attempted: 1)) {
      try await client.send(self.syncState(revision: 1))
    }
    #expect(await client.sentStates.map(\.revision) == [2])
  }

  @Test func receiveKeepsNewestRevision() async {
    let client = MockCompanionStateSyncClient(state: .activated)
    await client.receive(syncState(revision: 5))
    await client.receive(syncState(revision: 3))
    #expect(await client.latestReceivedState()?.revision == 5)
  }

  @Test func sendBeforeActivationFails() async {
    let client = MockCompanionStateSyncClient()
    await #expect(throws: ConnectivityAdapterError.unavailable("Connectivity is not activated")) {
      try await client.send(self.syncState(revision: 1))
    }
  }

  private func syncState(revision: UInt64) -> CompanionSyncState {
    CompanionSyncState(
      revision: revision,
      updatedAt: Date(timeIntervalSince1970: TimeInterval(revision)),
      values: ["outfit": "forest"]
    )
  }
}
