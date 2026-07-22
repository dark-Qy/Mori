import Domain
import Foundation

public enum EventLedgerError: Error, Equatable, Sendable {
  case unsupportedLedgerSchema(Int)
  case unsupportedEventSchema(Int)
  case unsupportedHealthSnapshotSchema(Int)
  case inconsistentHealthSettlementDay
  case conflictingEventID(UUID)
}

/// The append-only source of truth. Derived companion state may be cached, but can always be rebuilt
/// from this canonical event sequence and the recorded rule versions.
public struct EventLedger: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public private(set) var schemaVersion: Int
  public private(set) var events: [EventEnvelope]

  public init(events: [EventEnvelope] = []) throws {
    schemaVersion = Self.currentSchemaVersion
    self.events = []
    for event in events.sorted(by: EventEnvelope.canonicalOrder) {
      try append(event)
    }
  }

  public mutating func append(_ event: EventEnvelope) throws {
    guard event.schemaVersion == EventEnvelope.currentSchemaVersion else {
      throw EventLedgerError.unsupportedEventSchema(event.schemaVersion)
    }
    if case .healthSnapshotReceived(let snapshot) = event.payload {
      guard snapshot.schemaVersion == HealthSnapshot.currentSchemaVersion else {
        throw EventLedgerError.unsupportedHealthSnapshotSchema(snapshot.schemaVersion)
      }
      guard snapshot.hasConsistentSettlementDay else {
        throw EventLedgerError.inconsistentHealthSettlementDay
      }
    }
    if let existing = events.first(where: { $0.eventID == event.eventID }) {
      guard existing == event else {
        throw EventLedgerError.conflictingEventID(event.eventID)
      }
      return
    }
    events.append(event)
    events.sort(by: EventEnvelope.canonicalOrder)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case events
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .schemaVersion)
    guard version == Self.currentSchemaVersion else {
      throw EventLedgerError.unsupportedLedgerSchema(version)
    }

    schemaVersion = version
    events = []
    for event in try container.decode([EventEnvelope].self, forKey: .events) {
      try append(event)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(events.sorted(by: EventEnvelope.canonicalOrder), forKey: .events)
  }
}

public struct EventLedgerCodec: Sendable {
  public init() {}

  public func encode(_ ledger: EventLedger) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(ledger)
  }

  public func decode(_ data: Data) throws -> EventLedger {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(EventLedger.self, from: data)
  }
}
