import Foundation

/// Stable identifiers shared by preferences, peer sync, and platform presentation layers.
///
/// The current home renders one character, but the persisted contract intentionally accepts
/// two ordered character slots so a future duo home does not require a storage migration.
public enum CompanionVisualCatalog {
  public static let defaultCharacterID = "penguin"
  public static let defaultBackgroundID = "spring_meadow_stream"
  public static let maximumCharacterCount = 2

  public static let characterIDs = [
    "penguin",
    "polar_bear",
    "bili_22",
    "bili_33",
  ]

  public static let backgroundIDs = [
    "ice_ocean_day",
    "spring_meadow_stream",
    "rainy_cabin_dusk",
    "moonlit_forest_camp",
    "snow_birch_sunrise",
    "summer_lake",
    "rainy_reading_room",
    "aurora_observatory",
    "sunset_coast",
    "lantern_festival_square",
  ]

  public static func normalizedCharacterIDs(_ values: [String]) -> [String] {
    var seen = Set<String>()
    let supported = Set(characterIDs)
    let normalized = values.filter { value in
      supported.contains(value) && seen.insert(value).inserted
    }
    return Array(normalized.prefix(maximumCharacterCount)).ifEmpty([defaultCharacterID])
  }

  public static func normalizedBackgroundID(_ value: String) -> String {
    backgroundIDs.contains(value) ? value : defaultBackgroundID
  }

  public static func characterDisplayName(_ id: String) -> String {
    switch id {
    case "polar_bear": "白熊伙伴"
    case "bili_22": "22 娘"
    case "bili_33": "33 娘"
    default: "企鹅伙伴"
    }
  }
}

extension Array {
  fileprivate func ifEmpty(_ fallback: @autoclosure () -> Self) -> Self {
    isEmpty ? fallback() : self
  }
}
