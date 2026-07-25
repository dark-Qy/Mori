import Foundation
import MoriDomain

public enum ExperienceEnvelopeCodecError: Error, Equatable, Sendable {
  case oversized(actualBytes: Int, maximumBytes: Int)
  case malformedJSON
  case forbiddenPayloadKey(String)
  case undeclaredField(String)
  case invalidEnvelope(MoriDomainRejection)
}

/// Defensive codec for the cross-device experience channel. The domain uses a
/// closed payload enum; this raw-key audit additionally prevents JSON decoders
/// from silently ignoring injected health, route, contact, secret, or chat keys.
public struct ExperienceEnvelopeCodec: Sendable {
  public static let defaultMaximumBytes = 64 * 1_024

  private static let forbiddenNormalizedKeys: Set<String> = [
    "apikey",
    "contacts",
    "conversation",
    "coordinate",
    "coordinates",
    "gpstrack",
    "healthkitsample",
    "healthkitsamples",
    "latitude",
    "longitude",
    "messages",
    "preciselocation",
    "providercredential",
    "providercredentials",
    "rawhealth",
    "route",
    "routes",
    "secret",
  ]

  private let maximumBytes: Int
  private let codec: CanonicalJSONCodec

  public init(
    maximumBytes: Int = Self.defaultMaximumBytes,
    codec: CanonicalJSONCodec = CanonicalJSONCodec()
  ) {
    self.maximumBytes = max(1, maximumBytes)
    self.codec = codec
  }

  public func encode(_ envelope: ExperienceSyncEnvelope) throws -> Data {
    if let rejection = envelope.validate() {
      throw ExperienceEnvelopeCodecError.invalidEnvelope(rejection)
    }
    let data = try codec.encode(envelope)
    try validateSize(data)
    return data
  }

  public func decode(_ data: Data) throws -> ExperienceSyncEnvelope {
    try validateSize(data)
    try auditRawKeys(in: data)
    let envelope = try codec.decode(ExperienceSyncEnvelope.self, from: data)
    if let rejection = envelope.validate() {
      throw ExperienceEnvelopeCodecError.invalidEnvelope(rejection)
    }
    try auditClosedShape(of: data, decodedAs: envelope)
    return envelope
  }

  private func validateSize(_ data: Data) throws {
    guard data.count <= maximumBytes else {
      throw ExperienceEnvelopeCodecError.oversized(
        actualBytes: data.count,
        maximumBytes: maximumBytes
      )
    }
  }

  private func auditRawKeys(in data: Data) throws {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw ExperienceEnvelopeCodecError.malformedJSON
    }
    if let forbidden = firstForbiddenKey(in: object) {
      throw ExperienceEnvelopeCodecError.forbiddenPayloadKey(forbidden)
    }
  }

  private func auditClosedShape(
    of sourceData: Data,
    decodedAs envelope: ExperienceSyncEnvelope
  ) throws {
    let source: Any
    let canonical: Any
    do {
      source = try JSONSerialization.jsonObject(with: sourceData)
      canonical = try JSONSerialization.jsonObject(with: codec.encode(envelope))
    } catch {
      throw ExperienceEnvelopeCodecError.malformedJSON
    }
    if let field = firstUndeclaredField(in: source, comparedTo: canonical, path: "$") {
      throw ExperienceEnvelopeCodecError.undeclaredField(field)
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
      guard let canonical = canonical as? [Any], source.count == canonical.count else {
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

  private func firstForbiddenKey(in value: Any) -> String? {
    if let dictionary = value as? [String: Any] {
      for (key, child) in dictionary {
        let normalized =
          key
          .lowercased()
          .filter { $0.isLetter || $0.isNumber }
        if Self.forbiddenNormalizedKeys.contains(normalized) {
          return key
        }
        if let nested = firstForbiddenKey(in: child) {
          return nested
        }
      }
    } else if let array = value as? [Any] {
      for child in array {
        if let nested = firstForbiddenKey(in: child) {
          return nested
        }
      }
    }
    return nil
  }
}
