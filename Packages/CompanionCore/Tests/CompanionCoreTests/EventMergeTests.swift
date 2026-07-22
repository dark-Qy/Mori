import Domain
import Foundation
import Sync
import Testing

@Suite("Offline event merge")
struct EventMergeTests {
  private let merger = EventMerger()
  private let start = Date(timeIntervalSince1970: 1_750_000_000)

  @Test("Merge deduplicates identity and returns canonical order")
  func mergeAndOrder() throws {
    let earlier = event(id: uuid(1), offset: 0, kind: "earlier")
    let later = event(id: uuid(2), offset: 30, kind: "later")

    let result = try merger.merge(local: [later, earlier], remote: [earlier])

    #expect(result == [earlier, later])
  }

  @Test("A reused event ID with different content fails closed")
  func mergeConflict() {
    let id = uuid(3)
    let local = event(id: id, offset: 0, kind: "tap")
    let remote = event(id: id, offset: 0, kind: "swipe")

    #expect(throws: EventMergeError.conflictingEventID(id)) {
      try merger.merge(local: [local], remote: [remote])
    }
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
