import Foundation

/// Stable JSON is used for durable retries and conflict detection. Dates remain
/// informational; logical revisions carry authority in the domain model.
public struct CanonicalJSONCodec: Sendable {
  public init() {}

  public func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  public func decode<Value: Decodable>(
    _ type: Value.Type,
    from data: Data
  ) throws -> Value {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(type, from: data)
  }
}
