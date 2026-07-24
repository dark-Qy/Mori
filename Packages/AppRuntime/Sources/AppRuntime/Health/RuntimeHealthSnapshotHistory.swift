import Domain
import Foundation

struct RuntimeHealthSnapshotHistory: Sendable {
  func snapshots(from events: [EventEnvelope]) -> [HealthSnapshot] {
    var latestByDay: [LocalDay: (event: EventEnvelope, snapshot: HealthSnapshot)] = [:]
    for event in events {
      guard case .healthSnapshotReceived(let snapshot) = event.payload else { continue }
      if let current = latestByDay[snapshot.localDay] {
        if isNewer(event: event, snapshot: snapshot, than: current) {
          latestByDay[snapshot.localDay] = (event, snapshot)
        }
      } else {
        latestByDay[snapshot.localDay] = (event, snapshot)
      }
    }
    return latestByDay.values
      .map(\.snapshot)
      .sorted { lhs, rhs in
        if lhs.localDay != rhs.localDay { return lhs.localDay < rhs.localDay }
        return lhs.capturedAt < rhs.capturedAt
      }
  }

  private func isNewer(
    event: EventEnvelope,
    snapshot: HealthSnapshot,
    than current: (event: EventEnvelope, snapshot: HealthSnapshot)
  ) -> Bool {
    if snapshot.capturedAt != current.snapshot.capturedAt {
      return snapshot.capturedAt > current.snapshot.capturedAt
    }
    return EventEnvelope.canonicalOrder(current.event, event)
  }
}
