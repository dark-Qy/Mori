import Foundation
import Testing

@testable import AppRuntime

@Suite("Peer sync revision clock")
struct SyncRevisionClockTests {
  @Test("Reservations are unique even when timestamps are identical or move backward")
  func reservationsAreMonotonic() {
    var clock = SyncRevisionClock()
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let revisions = (0..<1_000).map { index in
      clock.reserve(at: index.isMultiple(of: 2) ? now : now.addingTimeInterval(-3_600))
    }

    #expect(Set(revisions).count == 1_000)
    #expect(zip(revisions, revisions.dropFirst()).allSatisfy { $0 < $1 })
    #expect(clock.lastRevision == revisions.last)
  }
}
