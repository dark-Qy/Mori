import Foundation

public enum HealthSharingScope: String, Codable, CaseIterable, Sendable {
  case gameStateOnly
  case careSummary
  case limitedHealthSummary
}

public struct AppPreferences: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1
  public static let currentNotificationConsentVersion = 1

  public var schemaVersion: Int
  public var hasCompletedOnboarding: Bool
  public var proactiveMessagesEnabled: Bool
  public var proactiveNotificationConsentVersion: Int
  public var socialSharingEnabled: Bool
  public var publicPetSocialState: PublicPetSocialStateV1
  public var healthSharingScope: HealthSharingScope
  public var selectedOutfitID: String
  public var selectedCharacterIDs: [String]
  public var selectedBackgroundID: String
  public var quietHoursStartMinute: Int
  public var quietHoursEndMinute: Int

  public init(
    schemaVersion: Int = AppPreferences.currentSchemaVersion,
    hasCompletedOnboarding: Bool = false,
    proactiveMessagesEnabled: Bool = false,
    proactiveNotificationConsentVersion: Int? = nil,
    socialSharingEnabled: Bool = false,
    publicPetSocialState: PublicPetSocialStateV1 = .greeting,
    healthSharingScope: HealthSharingScope = .careSummary,
    selectedOutfitID: String = "default",
    selectedCharacterIDs: [String] = [CompanionVisualCatalog.defaultCharacterID],
    selectedBackgroundID: String = CompanionVisualCatalog.defaultBackgroundID,
    quietHoursStartMinute: Int = 22 * 60,
    quietHoursEndMinute: Int = 7 * 60
  ) {
    self.schemaVersion = schemaVersion
    self.hasCompletedOnboarding = hasCompletedOnboarding
    self.proactiveMessagesEnabled = proactiveMessagesEnabled
    self.proactiveNotificationConsentVersion =
      proactiveNotificationConsentVersion
      ?? (proactiveMessagesEnabled ? Self.currentNotificationConsentVersion : 0)
    self.socialSharingEnabled = socialSharingEnabled
    self.publicPetSocialState = publicPetSocialState
    self.healthSharingScope = healthSharingScope
    self.selectedOutfitID = selectedOutfitID
    self.selectedCharacterIDs =
      CompanionVisualCatalog.normalizedCharacterIDs(selectedCharacterIDs)
    self.selectedBackgroundID =
      CompanionVisualCatalog.normalizedBackgroundID(selectedBackgroundID)
    self.quietHoursStartMinute = max(0, min(1_439, quietHoursStartMinute))
    self.quietHoursEndMinute = max(0, min(1_439, quietHoursEndMinute))
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case hasCompletedOnboarding
    case proactiveMessagesEnabled
    case proactiveNotificationConsentVersion
    case socialSharingEnabled
    case publicPetSocialState
    case healthSharingScope
    case selectedOutfitID
    case selectedCharacterIDs
    case selectedBackgroundID
    case quietHoursStartMinute
    case quietHoursEndMinute
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    // Existing version-1 installs predate onboarding. Treat those records as completed so an
    // update never unexpectedly blocks the app behind a new introduction screen.
    hasCompletedOnboarding =
      try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)
      ?? true
    let consentVersion =
      try container.decodeIfPresent(
        Int.self,
        forKey: .proactiveNotificationConsentVersion
      ) ?? 0
    proactiveNotificationConsentVersion = consentVersion
    let storedProactive =
      try container.decodeIfPresent(
        Bool.self,
        forKey: .proactiveMessagesEnabled
      ) ?? false
    proactiveMessagesEnabled =
      storedProactive
      && consentVersion >= Self.currentNotificationConsentVersion
    socialSharingEnabled =
      try container.decodeIfPresent(
        Bool.self,
        forKey: .socialSharingEnabled
      ) ?? false
    publicPetSocialState =
      try container.decodeIfPresent(
        PublicPetSocialStateV1.self,
        forKey: .publicPetSocialState
      ) ?? .greeting
    healthSharingScope =
      try container.decodeIfPresent(
        HealthSharingScope.self,
        forKey: .healthSharingScope
      ) ?? .careSummary
    selectedOutfitID =
      try container.decodeIfPresent(String.self, forKey: .selectedOutfitID)
      ?? "default"
    selectedCharacterIDs = CompanionVisualCatalog.normalizedCharacterIDs(
      try container.decodeIfPresent([String].self, forKey: .selectedCharacterIDs)
        ?? [CompanionVisualCatalog.defaultCharacterID]
    )
    selectedBackgroundID = CompanionVisualCatalog.normalizedBackgroundID(
      try container.decodeIfPresent(String.self, forKey: .selectedBackgroundID)
        ?? CompanionVisualCatalog.defaultBackgroundID
    )
    quietHoursStartMinute = max(
      0,
      min(1_439, try container.decodeIfPresent(Int.self, forKey: .quietHoursStartMinute) ?? 1_320)
    )
    quietHoursEndMinute = max(
      0,
      min(1_439, try container.decodeIfPresent(Int.self, forKey: .quietHoursEndMinute) ?? 420)
    )
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
