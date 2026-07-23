import Foundation

/// The only social status that may be placed on a public encounter card.
///
/// These values are deliberately user-selected play intentions. They are not
/// inferred from HealthKit, vitality, mood, sleep, or any other private signal.
public enum PublicPetSocialStateV1: String, Codable, CaseIterable, Sendable {
  case greeting
  case walk
  case quietCompany = "quiet_company"
}

public enum PublicPetCardError: Error, Equatable, Sendable {
  case unsupportedSchemaVersion(String)
  case disallowedField(String)
  case invalidPetName
  case invalidAssetID(String)
}

/// Version 1 of the game-only card exchanged after proximity has been proven.
///
/// New fields must remain explicitly selected, cosmetic game data. Private
/// runtime state such as health, vitality, mood, sleep, and inferred theme do
/// not belong in this transport type.
public struct PublicPetCardV1: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = "public_pet_card_v1"

  public let schemaVersion: String
  public let petName: String
  public let characterID: String
  public let outfitID: String?
  public let backgroundID: String?
  public let socialState: PublicPetSocialStateV1

  public init(
    petName: String,
    characterID: String,
    outfitID: String? = nil,
    backgroundID: String? = nil,
    socialState: PublicPetSocialStateV1
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.petName = petName
    self.characterID = characterID
    self.outfitID = outfitID
    self.backgroundID = backgroundID
    self.socialState = socialState
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case petName = "pet_name"
    case characterID = "character_id"
    case outfitID = "outfit_id"
    case backgroundID = "background_id"
    case socialState = "social_state"
  }

  public init(from decoder: any Decoder) throws {
    let rawValues = try decoder.container(keyedBy: AnyCodingKey.self)
    let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
    if let disallowedKey = rawValues.allKeys.first(where: {
      !allowedKeys.contains($0.stringValue)
    }) {
      throw PublicPetCardError.disallowedField(disallowedKey.stringValue)
    }

    let values = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try values.decode(String.self, forKey: .schemaVersion)
    guard schemaVersion == Self.currentSchemaVersion else {
      throw PublicPetCardError.unsupportedSchemaVersion(schemaVersion)
    }
    self.schemaVersion = schemaVersion
    petName = try values.decode(String.self, forKey: .petName)
    characterID = try values.decode(String.self, forKey: .characterID)
    outfitID = try values.decodeIfPresent(String.self, forKey: .outfitID)
    backgroundID = try values.decodeIfPresent(String.self, forKey: .backgroundID)
    socialState = try values.decode(
      PublicPetSocialStateV1.self,
      forKey: .socialState
    )
  }

  public func validateForTransport() throws {
    guard (1...32).contains(petName.count),
      !petName.unicodeScalars.contains(where: {
        $0.value < 32 || $0.value == 127
      })
    else {
      throw PublicPetCardError.invalidPetName
    }
    for assetID in [characterID, outfitID, backgroundID].compactMap({ $0 }) {
      guard (1...64).contains(assetID.count),
        let first = assetID.first,
        first.isASCIIAlphaNumeric,
        assetID.allSatisfy({
          $0.isASCIIAlphaNumeric || $0 == "." || $0 == "_" || $0 == "-"
        })
      else {
        throw PublicPetCardError.invalidAssetID(assetID)
      }
    }
  }

  private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
      self.stringValue = stringValue
      intValue = nil
    }

    init?(intValue: Int) {
      stringValue = String(intValue)
      self.intValue = intValue
    }
  }
}

extension Character {
  fileprivate var isASCIIAlphaNumeric: Bool {
    ("a"..."z").contains(self)
      || ("A"..."Z").contains(self)
      || ("0"..."9").contains(self)
  }
}
