import Domain
import Foundation
import Growth
import Testing

@Suite("Relationship presence")
struct RelationshipPresenceTests {
  private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

  @Test("A new companion never starts by making the person feel guilty")
  func noInteractionHistoryIsNeutral() {
    #expect(
      PetState().relationshipPresence(at: date("2026-07-23T12:00:00+08:00"), timeZone: timeZone)
        == .present
    )
  }

  @Test("Mori quietly misses the person only after three complete local days")
  func threeCompleteDays() {
    let pet = PetState(lastInteractionAt: date("2026-07-19T23:30:00+08:00"))

    #expect(
      pet.relationshipPresence(at: date("2026-07-22T23:59:59+08:00"), timeZone: timeZone)
        == .present
    )
    #expect(
      pet.relationshipPresence(at: date("2026-07-23T00:00:00+08:00"), timeZone: timeZone)
        == .quietlyMissingYou
    )
  }

  @Test("An explicit interaction restores presence without changing vitality")
  func interactionRestoresPresenceWithoutPenalty() throws {
    let interactionDate = date("2026-07-23T09:00:00+08:00")
    var state = CompanionState(
      pet: PetState(lastInteractionAt: date("2026-07-19T09:00:00+08:00")),
      growth: GrowthState(vitality: 42)
    )
    let event = EventEnvelope(
      eventID: UUID(),
      occurredAt: interactionDate,
      source: .watch,
      payload: .petInteracted(PetInteraction(kind: "comfort"))
    )

    try CompanionReducer().reduce(&state, event: event)

    #expect(state.pet.lastInteractionAt == interactionDate)
    #expect(state.pet.relationshipPresence(at: interactionDate, timeZone: timeZone) == .present)
    #expect(state.growth.vitality == 42)
  }

  private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }
}
