import Foundation
import Testing

@testable import AppRuntime

@Suite("Durable management sync outbox")
struct ManagementSyncOutboxTests {
  @Test("Pending latest value survives repository reconstruction")
  func pendingSurvivesRelaunch() async throws {
    let storage = InMemoryManagementSyncOutboxStorage()
    let first = ManagementSyncOutbox(storage: storage)
    let operation = try await first.enqueue(
      values: ["outfit": "leaf"],
      updatedAt: Date(timeIntervalSince1970: 100),
      operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    )

    let relaunched = ManagementSyncOutbox(storage: storage)
    #expect(try await relaunched.pendingOperation() == operation)
  }

  @Test("Rapid changes coalesce to the newest management state")
  func coalescesLatestValue() async throws {
    let outbox = ManagementSyncOutbox(storage: InMemoryManagementSyncOutboxStorage())
    let first = try await outbox.enqueue(
      values: ["outfit": "leaf"],
      updatedAt: Date(timeIntervalSince1970: 200)
    )
    let second = try await outbox.enqueue(
      values: ["outfit": "soccer_scarf"],
      updatedAt: Date(timeIntervalSince1970: 201)
    )

    #expect(second.revision > first.revision)
    #expect(try await outbox.pendingOperation() == second)
  }

  @Test("Identical pending values are idempotent")
  func duplicatePendingValueIsIdempotent() async throws {
    let outbox = ManagementSyncOutbox(storage: InMemoryManagementSyncOutboxStorage())
    let first = try await outbox.enqueue(
      values: ["outfit": "leaf"],
      updatedAt: Date(timeIntervalSince1970: 300)
    )
    let duplicate = try await outbox.enqueue(
      values: ["outfit": "leaf"],
      updatedAt: Date(timeIntervalSince1970: 400)
    )

    #expect(duplicate == first)
  }

  @Test("Acknowledgement clears only the delivered revision")
  func acknowledgeClearsDeliveredOperation() async throws {
    let outbox = ManagementSyncOutbox(storage: InMemoryManagementSyncOutboxStorage())
    let pending = try await outbox.enqueue(
      values: ["outfit": "leaf"],
      updatedAt: Date(timeIntervalSince1970: 500)
    )

    try await outbox.acknowledge(revision: pending.revision - 1)
    #expect(try await outbox.pendingOperation() == pending)
    try await outbox.acknowledge(revision: pending.revision)
    #expect(try await outbox.pendingOperation() == nil)
  }

  @Test("Revision remains monotonic across acknowledgement, relaunch, and clock rollback")
  func revisionPersistsAcrossClockRollback() async throws {
    let storage = InMemoryManagementSyncOutboxStorage()
    let firstOutbox = ManagementSyncOutbox(storage: storage)
    let first = try await firstOutbox.enqueue(
      values: ["outfit": "leaf"],
      updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    try await firstOutbox.acknowledge(revision: first.revision)

    let relaunched = ManagementSyncOutbox(storage: storage)
    let second = try await relaunched.enqueue(
      values: ["outfit": "default"],
      updatedAt: Date(timeIntervalSince1970: 10)
    )

    #expect(second.revision == first.revision + 1)
  }
}
