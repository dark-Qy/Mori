import Foundation

final class AdapterEventBroadcaster<Event: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

  func stream(bufferingNewest limit: Int = 16) -> AsyncStream<Event> {
    let identifier = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(limit)) { continuation in
      lock.withLock {
        continuations[identifier] = continuation
      }
      continuation.onTermination = { [weak self] _ in
        _ = self?.lock.withLock {
          self?.continuations.removeValue(forKey: identifier)
        }
      }
    }
  }

  func yield(_ event: Event) {
    let current = lock.withLock { Array(continuations.values) }
    for continuation in current {
      continuation.yield(event)
    }
  }
}
