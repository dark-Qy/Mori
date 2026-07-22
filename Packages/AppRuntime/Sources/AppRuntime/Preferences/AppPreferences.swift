import Foundation

public enum HealthSharingScope: String, Codable, CaseIterable, Sendable {
  case gameStateOnly
  case careSummary
  case limitedHealthSummary
}

public struct AppPreferences: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var proactiveMessagesEnabled: Bool
  public var socialSharingEnabled: Bool
  public var healthSharingScope: HealthSharingScope
  public var selectedOutfitID: String
  public var quietHoursStartMinute: Int
  public var quietHoursEndMinute: Int

  public init(
    schemaVersion: Int = AppPreferences.currentSchemaVersion,
    proactiveMessagesEnabled: Bool = true,
    socialSharingEnabled: Bool = false,
    healthSharingScope: HealthSharingScope = .careSummary,
    selectedOutfitID: String = "default",
    quietHoursStartMinute: Int = 22 * 60,
    quietHoursEndMinute: Int = 7 * 60
  ) {
    self.schemaVersion = schemaVersion
    self.proactiveMessagesEnabled = proactiveMessagesEnabled
    self.socialSharingEnabled = socialSharingEnabled
    self.healthSharingScope = healthSharingScope
    self.selectedOutfitID = selectedOutfitID
    self.quietHoursStartMinute = max(0, min(1_439, quietHoursStartMinute))
    self.quietHoursEndMinute = max(0, min(1_439, quietHoursEndMinute))
  }
}

public protocol PreferencesDataStore: Sendable {
  func load() async throws -> Data?
  func save(_ data: Data) async throws
}

public actor InMemoryPreferencesDataStore: PreferencesDataStore {
  private var data: Data?

  public init(data: Data? = nil) { self.data = data }
  public func load() -> Data? { data }
  public func save(_ data: Data) { self.data = data }
}

public actor UserDefaultsPreferencesDataStore: PreferencesDataStore {
  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, key: String = "app.preferences.v1") {
    self.defaults = defaults
    self.key = key
  }

  public func load() -> Data? { defaults.data(forKey: key) }
  public func save(_ data: Data) { defaults.set(data, forKey: key) }
}

public enum PreferencesRepositoryError: Error, Equatable, Sendable {
  case unsupportedSchema(Int)
}

public actor PreferencesRepository<Store: PreferencesDataStore> {
  private let store: Store
  private var cached: AppPreferences?

  public init(store: Store) { self.store = store }

  public func load() async throws -> AppPreferences {
    if let cached { return cached }
    guard let data = try await store.load() else {
      let defaults = AppPreferences()
      cached = defaults
      return defaults
    }
    let value = try JSONDecoder().decode(AppPreferences.self, from: data)
    guard value.schemaVersion == AppPreferences.currentSchemaVersion else {
      throw PreferencesRepositoryError.unsupportedSchema(value.schemaVersion)
    }
    cached = value
    return value
  }

  public func save(_ value: AppPreferences) async throws {
    guard value.schemaVersion == AppPreferences.currentSchemaVersion else {
      throw PreferencesRepositoryError.unsupportedSchema(value.schemaVersion)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try await store.save(encoder.encode(value))
    cached = value
  }
}
