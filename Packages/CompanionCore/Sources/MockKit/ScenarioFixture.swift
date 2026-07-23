#if DEBUG
  import Foundation

  public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if container.decodeNil() {
        self = .null
      } else if let value = try? container.decode(Bool.self) {
        self = .bool(value)
      } else if let value = try? container.decode(Double.self) {
        self = .number(value)
      } else if let value = try? container.decode(String.self) {
        self = .string(value)
      } else if let value = try? container.decode([String: JSONValue].self) {
        self = .object(value)
      } else if let value = try? container.decode([JSONValue].self) {
        self = .array(value)
      } else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Unsupported JSON value."
        )
      }
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .object(let value): try container.encode(value)
      case .array(let value): try container.encode(value)
      case .string(let value): try container.encode(value)
      case .number(let value): try container.encode(value)
      case .bool(let value): try container.encode(value)
      case .null: try container.encodeNil()
      }
    }
  }

  extension JSONValue {
    public var objectValue: [String: JSONValue]? {
      guard case .object(let value) = self else { return nil }
      return value
    }

    public var arrayValue: [JSONValue]? {
      guard case .array(let value) = self else { return nil }
      return value
    }

    public var stringValue: String? {
      guard case .string(let value) = self else { return nil }
      return value
    }

    public var numberValue: Double? {
      guard case .number(let value) = self else { return nil }
      return value
    }

    public var boolValue: Bool? {
      guard case .bool(let value) = self else { return nil }
      return value
    }

    public subscript(key: String) -> JSONValue? {
      objectValue?[key]
    }
  }

  public struct ScenarioFixture: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Clock: Codable, Equatable, Sendable {
      public var now: Date
      public var timeZone: String
    }

    public var schemaVersion: Int
    public var scenarioID: String
    public var displayName: String
    public var clock: Clock
    public var launchArguments: [String]
    public var state: JSONValue
    public var expectations: JSONValue

    public init(data: Data) throws {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      self = try decoder.decode(Self.self, from: data)
    }

    public init(contentsOf url: URL) throws {
      try self.init(data: Data(contentsOf: url))
    }

    public func validationIssues(fileStem: String) -> [String] {
      var issues: [String] = []
      if schemaVersion != Self.currentSchemaVersion {
        issues.append("unsupported schemaVersion")
      }
      if scenarioID != fileStem {
        issues.append("scenarioID must match its filename")
      }
      if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append("displayName must not be empty")
      }
      if TimeZone(identifier: clock.timeZone) == nil {
        issues.append("clock.timeZone must be an IANA time zone")
      }
      if launchArguments != ["-MockScenario", scenarioID] {
        issues.append("launchArguments must select this exact scenario")
      }
      guard case .object(let expectations) = expectations else {
        issues.append("expectations must be an object")
        return issues
      }
      if expectations["mockBadgeVisible"] != .bool(true) {
        issues.append("mockBadgeVisible must be true")
      }
      return issues
    }
  }
#endif
