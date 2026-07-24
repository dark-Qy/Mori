import Foundation
import MoriPersistence

public enum GlobalAuthoritySyncChannel: String, CaseIterable, Codable, Sendable {
  case preferences
  case consent
}

public struct GlobalPreferenceSyncFrame: Codable, Equatable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let preferences: GlobalSyncedPreferences

  public init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    preferences: GlobalSyncedPreferences
  ) {
    self.schemaVersion = schemaVersion
    self.preferences = preferences
  }

  public var isValid: Bool {
    schemaVersion == Self.currentSchemaVersion && preferences.isValid
  }
}

public struct GlobalConsentSyncFrame: Codable, Equatable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let consent: GlobalConsentState

  public init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    consent: GlobalConsentState
  ) {
    self.schemaVersion = schemaVersion
    self.consent = consent
  }

  public var isValid: Bool {
    schemaVersion == Self.currentSchemaVersion && consent.isValid
  }
}

public enum GlobalAuthoritySyncWireError: Error, Equatable, Sendable {
  case oversized(actualBytes: Int, maximumBytes: Int)
  case malformed
  case undeclaredField(String)
  case nonCanonical
  case unsupportedSchema(UInt16)
  case invalidPreferences
  case invalidConsent
}

/// Closed, bounded, canonical wire for the two global authority channels.
///
/// Device-local capability and route state cannot enter either frame because
/// the wire exposes only the closed preference and consent domain values.
public struct GlobalAuthoritySyncWireCodec: Sendable {
  public static let defaultMaximumBytes = 32 * 1_024

  private let maximumBytes: Int
  private let codec: CanonicalJSONCodec

  public init(
    maximumBytes: Int = Self.defaultMaximumBytes,
    codec: CanonicalJSONCodec = CanonicalJSONCodec()
  ) {
    self.maximumBytes = max(1, maximumBytes)
    self.codec = codec
  }

  public func encode(_ frame: GlobalPreferenceSyncFrame) throws -> Data {
    guard frame.schemaVersion == GlobalPreferenceSyncFrame.currentSchemaVersion
    else {
      throw GlobalAuthoritySyncWireError.unsupportedSchema(frame.schemaVersion)
    }
    guard frame.preferences.isValid else {
      throw GlobalAuthoritySyncWireError.invalidPreferences
    }
    return try encodeCanonical(frame)
  }

  public func encode(_ frame: GlobalConsentSyncFrame) throws -> Data {
    guard frame.schemaVersion == GlobalConsentSyncFrame.currentSchemaVersion
    else {
      throw GlobalAuthoritySyncWireError.unsupportedSchema(frame.schemaVersion)
    }
    guard frame.consent.isValid else {
      throw GlobalAuthoritySyncWireError.invalidConsent
    }
    return try encodeCanonical(frame)
  }

  public func decodePreferences(_ data: Data) throws -> GlobalPreferenceSyncFrame {
    try validateSize(data)
    let frame: GlobalPreferenceSyncFrame
    do {
      frame = try codec.decode(GlobalPreferenceSyncFrame.self, from: data)
    } catch {
      throw GlobalAuthoritySyncWireError.malformed
    }
    guard frame.schemaVersion == GlobalPreferenceSyncFrame.currentSchemaVersion
    else {
      throw GlobalAuthoritySyncWireError.unsupportedSchema(frame.schemaVersion)
    }
    guard frame.preferences.isValid else {
      throw GlobalAuthoritySyncWireError.invalidPreferences
    }
    try validateClosedCanonical(data, value: frame)
    return frame
  }

  public func decodeConsent(_ data: Data) throws -> GlobalConsentSyncFrame {
    try validateSize(data)
    let frame: GlobalConsentSyncFrame
    do {
      frame = try codec.decode(GlobalConsentSyncFrame.self, from: data)
    } catch {
      throw GlobalAuthoritySyncWireError.malformed
    }
    guard frame.schemaVersion == GlobalConsentSyncFrame.currentSchemaVersion
    else {
      throw GlobalAuthoritySyncWireError.unsupportedSchema(frame.schemaVersion)
    }
    guard frame.consent.isValid else {
      throw GlobalAuthoritySyncWireError.invalidConsent
    }
    try validateClosedCanonical(data, value: frame)
    return frame
  }

  private func encodeCanonical<Value: Encodable>(_ value: Value) throws -> Data {
    let data = try codec.encode(value)
    try validateSize(data)
    return data
  }

  private func validateSize(_ data: Data) throws {
    guard data.count <= maximumBytes else {
      throw GlobalAuthoritySyncWireError.oversized(
        actualBytes: data.count,
        maximumBytes: maximumBytes
      )
    }
  }

  private func validateClosedCanonical<Value: Encodable>(
    _ sourceData: Data,
    value: Value
  ) throws {
    let canonicalData = try codec.encode(value)
    try validateSize(canonicalData)
    let source: Any
    let canonical: Any
    do {
      source = try JSONSerialization.jsonObject(with: sourceData)
      canonical = try JSONSerialization.jsonObject(with: canonicalData)
    } catch {
      throw GlobalAuthoritySyncWireError.malformed
    }
    if let field = firstUndeclaredField(
      in: source,
      comparedTo: canonical,
      path: "$"
    ) {
      throw GlobalAuthoritySyncWireError.undeclaredField(field)
    }
    guard sourceData == canonicalData else {
      throw GlobalAuthoritySyncWireError.nonCanonical
    }
  }

  private func firstUndeclaredField(
    in source: Any,
    comparedTo canonical: Any,
    path: String
  ) -> String? {
    if let source = source as? [String: Any] {
      guard let canonical = canonical as? [String: Any] else { return path }
      for key in source.keys.sorted() {
        guard let canonicalValue = canonical[key] else {
          return "\(path).\(key)"
        }
        if let field = firstUndeclaredField(
          in: source[key]!,
          comparedTo: canonicalValue,
          path: "\(path).\(key)"
        ) {
          return field
        }
      }
      return nil
    }
    if let source = source as? [Any] {
      guard let canonical = canonical as? [Any], source.count == canonical.count
      else {
        return path
      }
      for index in source.indices {
        if let field = firstUndeclaredField(
          in: source[index],
          comparedTo: canonical[index],
          path: "\(path)[\(index)]"
        ) {
          return field
        }
      }
    }
    return nil
  }
}
