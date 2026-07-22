import Domain
import Foundation

public struct PersistedCompanionState: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var state: CompanionState

  public init(
    schemaVersion: Int = PersistedCompanionState.currentSchemaVersion,
    state: CompanionState
  ) {
    self.schemaVersion = schemaVersion
    self.state = state
  }
}

public enum PersistenceError: Error, Equatable, Sendable {
  case malformedEnvelope
  case unsupportedFutureSchema(Int)
  case unsupportedStateSchema(Int)
  case migrationUnavailable(from: Int, to: Int)
}

/// Implement this protocol when a real legacy schema is introduced.
public protocol CompanionStateMigrating {
  func migrate(_ data: Data, from sourceVersion: Int, to targetVersion: Int) throws -> Data
}

public struct RejectingStateMigrator: CompanionStateMigrating {
  public init() {}

  public func migrate(_ data: Data, from sourceVersion: Int, to targetVersion: Int) throws -> Data {
    throw PersistenceError.migrationUnavailable(from: sourceVersion, to: targetVersion)
  }
}

public struct CompanionStateCodec: Sendable {
  public init() {}

  public func encode(_ state: CompanionState) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(PersistedCompanionState(state: state))
  }

  public func decode<M: CompanionStateMigrating>(
    _ data: Data,
    migrator: M
  ) throws -> CompanionState {
    let version = try schemaVersion(in: data)
    guard version <= PersistedCompanionState.currentSchemaVersion else {
      throw PersistenceError.unsupportedFutureSchema(version)
    }

    let currentData: Data
    if version < PersistedCompanionState.currentSchemaVersion {
      currentData = try migrator.migrate(
        data,
        from: version,
        to: PersistedCompanionState.currentSchemaVersion
      )
    } else {
      currentData = data
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let envelope = try decoder.decode(PersistedCompanionState.self, from: currentData)
    guard envelope.state.schemaVersion == CompanionState.currentSchemaVersion else {
      throw PersistenceError.unsupportedStateSchema(envelope.state.schemaVersion)
    }
    return envelope.state
  }

  public func decode(_ data: Data) throws -> CompanionState {
    try decode(data, migrator: RejectingStateMigrator())
  }

  private func schemaVersion(in data: Data) throws -> Int {
    guard
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = object["schemaVersion"] as? Int
    else {
      throw PersistenceError.malformedEnvelope
    }
    return version
  }
}
