import Foundation

struct SyncRevisionClock: Sendable {
  private(set) var lastRevision: UInt64 = 0

  mutating func reserve(at date: Date) -> UInt64 {
    let clockRevision = UInt64(max(0, date.timeIntervalSince1970 * 1_000))
    let revision = max(lastRevision &+ 1, clockRevision)
    lastRevision = revision
    return revision
  }
}
