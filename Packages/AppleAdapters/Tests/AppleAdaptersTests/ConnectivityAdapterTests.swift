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

  @Test func productionActivationGateTimesOutInsteadOfHanging() async {
    let gate = ConnectivityActivationGate(timeoutNanoseconds: 1_000_000)
    let result = await gate.wait(currentState: { .inactive }, startActivation: {})
    #expect(
      result
        == .unavailable(reason: "WatchConnectivity activation timed out")
    )
    #expect(gate.pendingWaiterCount() == 0)
  }

  @Test func productionActivationGateStartsOnceAndResolvesAllWaiters() async {
    let gate = ConnectivityActivationGate(timeoutNanoseconds: 1_000_000_000)
    let counter = LockedCounter()
    async let first = gate.wait(
      currentState: { .inactive },
      startActivation: { counter.increment() }
    )
    async let second = gate.wait(
      currentState: { .inactive },
      startActivation: { counter.increment() }
    )

    while gate.pendingWaiterCount() < 2 {
      await Task.yield()
    }
    gate.resolve(.activated)

    #expect(await first == .activated)
    #expect(await second == .activated)
    #expect(counter.value == 1)
  }

  @Test func productionActivationGateRechecksStateBeforeRegisteringWaiter() async {
    let gate = ConnectivityActivationGate(timeoutNanoseconds: 1_000_000)
    let counter = LockedCounter()

    // Models WCSession completing after the client's first read but before gate registration.
    gate.resolve(.activated)
    let result = await gate.wait(
      currentState: { .activated },
      startActivation: { counter.increment() }
    )

    #expect(result == .activated)
    #expect(counter.value == 0)
    #expect(gate.pendingWaiterCount() == 0)
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

  @Test func receivedStateStreamPublishesOnlyNewerValues() async throws {
    let client = MockCompanionStateSyncClient(state: .activated)
    let stream = await client.receivedStates()
    var iterator = stream.makeAsyncIterator()

    await client.receive(syncState(revision: 2))
    #expect(await iterator.next()?.revision == 2)
    await client.receive(syncState(revision: 1))
    await client.receive(syncState(revision: 3))
    #expect(await iterator.next()?.revision == 3)
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

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int { lock.withLock { count } }

  func increment() {
    lock.withLock { count += 1 }
  }
}
