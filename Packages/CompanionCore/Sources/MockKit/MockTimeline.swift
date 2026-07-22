import Domain
import Foundation
import Growth

public struct MockTimeline: Sendable {
  public var events: [EventEnvelope]

  public init(events: [EventEnvelope]) {
    self.events = events
  }

  public func replay(using reducer: CompanionReducer = CompanionReducer()) throws -> CompanionState
  {
    try reducer.replay(events)
  }

  public static func sevenDayFixture(startingAt start: Date) -> MockTimeline {
    let ids = [
      "00000000-0000-0000-0000-000000000001",
      "00000000-0000-0000-0000-000000000002",
      "00000000-0000-0000-0000-000000000003",
      "00000000-0000-0000-0000-000000000004",
      "00000000-0000-0000-0000-000000000005",
      "00000000-0000-0000-0000-000000000006",
      "00000000-0000-0000-0000-000000000007",
    ].compactMap(UUID.init(uuidString:))

    let events = ids.enumerated().map { index, id in
      let date = start.addingTimeInterval(TimeInterval(index * 86_400))
      return EventEnvelope(
        eventID: id,
        occurredAt: date,
        source: .mock,
        payload: .healthSnapshotReceived(
          index == 2 ? HealthFixtures.lowSleep(at: date) : HealthFixtures.normal(at: date)
        )
      )
    }
    return MockTimeline(events: events)
  }
}
