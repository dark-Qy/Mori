import Foundation

public enum WardrobeCatalog {
  public static let defaultOutfitID = "default"
  public static let supportedOutfitIDs: Set<String> = [
    defaultOutfitID,
    "soccer_scarf",
    "scarf",  // Legacy Phase 0 identifier; retained for migration compatibility.
    "leaf",
    "star",
    "drop",
  ]

  public static func contains(_ id: String) -> Bool {
    supportedOutfitIDs.contains(id)
  }
}

public struct WardrobeSessionState: Equatable, Sendable {
  public var selectedOutfitID: String
  public var previewOutfitID: String
  public var unlockedOutfitIDs: Set<String>

  public init(
    selectedOutfitID: String,
    previewOutfitID: String,
    unlockedOutfitIDs: Set<String>
  ) {
    self.selectedOutfitID = selectedOutfitID
    self.previewOutfitID = previewOutfitID
    self.unlockedOutfitIDs = unlockedOutfitIDs
  }
}

public enum WardrobeSelectionError: Error, Equatable, Sendable {
  case unknownOutfit(String)
  case lockedOutfit(String)
}

public struct WardrobeMutation: Equatable, Sendable {
  public let state: WardrobeSessionState
  public let selectionChanged: Bool
}

/// Pure preview/equip/reset policy. Preview is non-authoritative; only equip/reset can change the
/// selected outfit that is persisted and synchronized.
public struct WardrobeService: Sendable {
  public init() {}

  public func preview(
    _ outfitID: String,
    in state: WardrobeSessionState
  ) throws -> WardrobeSessionState {
    guard WardrobeCatalog.contains(outfitID) else {
      throw WardrobeSelectionError.unknownOutfit(outfitID)
    }
    var updated = state
    updated.previewOutfitID = outfitID
    return updated
  }

  public func equipPreview(in state: WardrobeSessionState) throws -> WardrobeMutation {
    guard WardrobeCatalog.contains(state.previewOutfitID) else {
      throw WardrobeSelectionError.unknownOutfit(state.previewOutfitID)
    }
    guard state.unlockedOutfitIDs.contains(state.previewOutfitID) else {
      throw WardrobeSelectionError.lockedOutfit(state.previewOutfitID)
    }
    var updated = state
    let changed = updated.selectedOutfitID != updated.previewOutfitID
    updated.selectedOutfitID = updated.previewOutfitID
    return WardrobeMutation(state: updated, selectionChanged: changed)
  }

  public func reset(_ state: WardrobeSessionState) throws -> WardrobeMutation {
    var previewed = try preview(WardrobeCatalog.defaultOutfitID, in: state)
    previewed.unlockedOutfitIDs.insert(WardrobeCatalog.defaultOutfitID)
    return try equipPreview(in: previewed)
  }
}
