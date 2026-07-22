import AppRuntime
import Domain
import Foundation
import Persistence
import Testing

@Suite("Companion event engine")
struct CompanionEventEngineTests {
  private let now = Date(timeIntervalSince1970: 1_760_000_000)

  @Test("Events persist and replay across engine instances")
  func durableReplay() async throws {
    let storage = InMemoryEventLedgerStorage()
    let first = CompanionEventEngine(storage: storage)
    let event = EventEnvelope(
      eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000771")!,
      occurredAt: now,
      source: .watch,
      payload: .petInteracted(PetInteraction(kind: "pet"))
    )

    let updated = try await first.append(event)
    let second = CompanionEventEngine(storage: storage)
    let replayed = try await second.currentState()

    #expect(updated == replayed)
    #expect(replayed.pet.lastInteractionAt == now)
    #expect(try await second.currentEvents() == [event])
  }

  @Test("Duplicate event identities stay idempotent")
  func duplicateAppend() async throws {
    let engine = CompanionEventEngine(storage: InMemoryEventLedgerStorage())
    let event = EventEnvelope(
      eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000772")!,
      occurredAt: now,
      source: .watch,
      payload: .petInteracted(PetInteraction(kind: "pet"))
    )

    let first = try await engine.append(event)
    let second = try await engine.append(event)

    #expect(first == second)
    #expect(second.processedEventIDs.count == 1)
  }
}
