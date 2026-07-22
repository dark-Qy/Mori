import Domain
import Foundation
import Growth
import MockKit
import Persistence
import Testing

@Suite("Versioned event ledger")
struct EventLedgerTests {
  private let start = Date(timeIntervalSince1970: 1_750_000_000)

  @Test("Append is idempotent and persists canonical order")
  func canonicalRoundTrip() throws {
    let earlier = event(id: uuid(1), offset: 0, kind: "tap")
    let later = event(id: uuid(2), offset: 60, kind: "wave")
    var ledger = try EventLedger(events: [later])
    try ledger.append(earlier)
    try ledger.append(earlier)

    let codec = EventLedgerCodec()
    let first = try codec.encode(ledger)
    let second = try codec.encode(ledger)
    let restored = try codec.decode(first)

    #expect(first == second)
    #expect(restored.events == [earlier, later])
  }

  @Test("Conflicting identity and unsupported schemas fail closed")
  func rejectsInvalidEvents() throws {
    let id = uuid(3)
    var ledger = try EventLedger(events: [event(id: id, offset: 0, kind: "tap")])

    #expect(throws: EventLedgerError.conflictingEventID(id)) {
      try ledger.append(event(id: id, offset: 0, kind: "swipe"))
    }

    let future = EventEnvelope(
      schemaVersion: 99,
      eventID: uuid(4),
      occurredAt: start,
      source: .mock,
      payload: .petInteracted(PetInteraction(kind: "tap"))
    )
    #expect(throws: EventLedgerError.unsupportedEventSchema(99)) {
      try ledger.append(future)
    }

    let futureSnapshot = HealthSnapshot(
      schemaVersion: 99,
      capturedAt: start,
      freshness: .fresh,
      requestState: .requestCompleted,
      availability: .available,
      steps: 8_000
    )
    let nestedFuture = EventEnvelope(
      eventID: uuid(7),
      occurredAt: start,
      source: .mock,
      payload: .healthSnapshotReceived(futureSnapshot)
    )
    #expect(throws: EventLedgerError.unsupportedHealthSnapshotSchema(99)) {
      try ledger.append(nestedFuture)
    }
  }

  @Test("Derived state is reproducible from a restored ledger")
  func replaysAfterRestore() throws {
    let health = EventEnvelope(
      eventID: uuid(5),
      occurredAt: start,
      source: .mock,
      payload: .healthSnapshotReceived(HealthFixtures.normal(at: start))
    )
    let interaction = event(id: uuid(6), offset: 30, kind: "tap")
    let ledger = try EventLedger(events: [interaction, health])
    let restored = try EventLedgerCodec().decode(EventLedgerCodec().encode(ledger))

    let first = try CompanionReducer().replay(ledger.events)
    let second = try CompanionReducer().replay(restored.events)

    #expect(first == second)
    #expect(second.growth.vitality == 5)
    #expect(second.pet.lastInteractionAt == start.addingTimeInterval(30))
  }

  private func event(id: UUID, offset: TimeInterval, kind: String) -> EventEnvelope {
    EventEnvelope(
      eventID: id,
      occurredAt: start.addingTimeInterval(offset),
      source: .mock,
      payload: .petInteracted(PetInteraction(kind: kind))
    )
  }

  private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
  }
}
