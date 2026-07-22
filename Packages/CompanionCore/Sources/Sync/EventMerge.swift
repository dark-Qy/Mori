import Domain
import Foundation

public enum EventMergeError: Error, Equatable, Sendable {
  case conflictingEventID(UUID)
}

/// Pure merge logic for a future transport adapter. It performs no I/O or networking.
public struct EventMerger: Sendable {
  public init() {}

  public func merge(local: [EventEnvelope], remote: [EventEnvelope]) throws -> [EventEnvelope] {
    var byID: [UUID: EventEnvelope] = [:]
    for event in local + remote {
      if let existing = byID[event.eventID], existing != event {
        throw EventMergeError.conflictingEventID(event.eventID)
      }
      byID[event.eventID] = event
    }
    return byID.values.sorted(by: EventEnvelope.canonicalOrder)
  }
}

public struct EventBatch: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var deviceID: String
  public var events: [EventEnvelope]

  public init(
    schemaVersion: Int = EventBatch.currentSchemaVersion,
    deviceID: String,
    events: [EventEnvelope]
  ) {
    self.schemaVersion = schemaVersion
    self.deviceID = deviceID
    self.events = events.sorted(by: EventEnvelope.canonicalOrder)
  }
}
