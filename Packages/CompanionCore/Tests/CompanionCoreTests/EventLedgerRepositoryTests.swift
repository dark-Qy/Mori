import Domain
import Foundation
import Persistence
import Testing

@Suite("Atomic event ledger repository")
struct EventLedgerRepositoryTests {
  @Test("Append persists and a new repository replays the same state")
  func appendAndReload() async throws {
    let storage = InMemoryEventLedgerStorage()
    let first = EventLedgerRepository(storage: storage)
    let event = interactionEvent(id: "00000000-0000-0000-0000-000000000101")

    let appendedState = try await first.append(event)
    let second = EventLedgerRepository(storage: storage)
    let reloadedState = try await second.currentState()

    #expect(reloadedState == appendedState)
    #expect(reloadedState.pet.lastInteractionAt == event.occurredAt)
  }

  @Test("Duplicate append remains idempotent on disk")
  func duplicateAppend() async throws {
    let storage = InMemoryEventLedgerStorage()
    let repository = EventLedgerRepository(storage: storage)
    let event = interactionEvent(id: "00000000-0000-0000-0000-000000000102")

    _ = try await repository.append(event)
    _ = try await repository.append(event)

    let ledger = try await repository.currentLedger()
    #expect(ledger.events == [event])
  }

  @Test("Malformed persisted bytes fail closed")
  func malformedBytes() async throws {
    let storage = InMemoryEventLedgerStorage(data: Data("not-json".utf8))
    let repository = EventLedgerRepository(storage: storage)

    await #expect(throws: (any Error).self) {
      _ = try await repository.currentLedger()
    }
  }

  @Test("File storage creates its directory and survives reopening")
  func fileRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("watch-companion-ledger-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("events.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let event = interactionEvent(id: "00000000-0000-0000-0000-000000000103")

    let first = EventLedgerRepository(storage: FileEventLedgerStorage(fileURL: fileURL))
    _ = try await first.append(event)
    let second = EventLedgerRepository(storage: FileEventLedgerStorage(fileURL: fileURL))

    #expect(try await second.currentLedger().events == [event])
  }

  private func interactionEvent(id: String) -> EventEnvelope {
    EventEnvelope(
      eventID: UUID(uuidString: id)!,
      occurredAt: Date(timeIntervalSince1970: 1_760_000_000),
      source: .watch,
      payload: .petInteracted(PetInteraction(kind: "pat"))
    )
  }
}
