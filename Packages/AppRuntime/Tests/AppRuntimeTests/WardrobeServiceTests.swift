import AppRuntime
import Testing

@Suite("Wardrobe selection policy")
struct WardrobeServiceTests {
  private let service = WardrobeService()

  @Test("Preview never changes the equipped outfit")
  func previewIsNonAuthoritative() throws {
    let state = fixtureState()
    let preview = try service.preview("soccer_scarf", in: state)

    #expect(preview.previewOutfitID == "soccer_scarf")
    #expect(preview.selectedOutfitID == "default")
  }

  @Test("Unlocked preview equips once and duplicate equip is idempotent")
  func equipUnlocked() throws {
    let preview = try service.preview("soccer_scarf", in: fixtureState())
    let first = try service.equipPreview(in: preview)
    let duplicate = try service.equipPreview(in: first.state)

    #expect(first.selectionChanged)
    #expect(first.state.selectedOutfitID == "soccer_scarf")
    #expect(!duplicate.selectionChanged)
  }

  @Test("Locked outfit may be previewed but cannot be equipped")
  func lockedOutfitFailsClosed() throws {
    var state = fixtureState()
    state.unlockedOutfitIDs = ["default"]
    let preview = try service.preview("soccer_scarf", in: state)

    #expect(throws: WardrobeSelectionError.lockedOutfit("soccer_scarf")) {
      try service.equipPreview(in: preview)
    }
  }

  @Test("Reset selects and previews the default outfit")
  func reset() throws {
    var state = fixtureState()
    state.selectedOutfitID = "soccer_scarf"
    state.previewOutfitID = "soccer_scarf"
    let reset = try service.reset(state)

    #expect(reset.selectionChanged)
    #expect(reset.state.selectedOutfitID == "default")
    #expect(reset.state.previewOutfitID == "default")
  }

  private func fixtureState() -> WardrobeSessionState {
    WardrobeSessionState(
      selectedOutfitID: "default",
      previewOutfitID: "default",
      unlockedOutfitIDs: ["default", "soccer_scarf"]
    )
  }
}
