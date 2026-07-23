import AppRuntime
import SwiftUI

struct WardrobeView: View {
  @ObservedObject var store: PhoneAppStore

  private let items = WardrobeItem.samples
  private let characters = CompanionCharacterOption.all
  private let backgrounds = CompanionBackgroundOption.all
  private var model: PhonePresentationModel { store.model }
  private var equippedItemID: String { store.preferences.selectedOutfitID }
  private var previewItemID: String { store.previewOutfitID }
  private var previewedItem: WardrobeItem? { items.first { $0.id == previewItemID } }
  private var previewIsUnlocked: Bool { store.unlockedOutfitIDs.contains(previewItemID) }
  private var selectedCharacterID: String {
    store.preferences.selectedCharacterIDs.first ?? CompanionVisualCatalog.defaultCharacterID
  }

  var body: some View {
    List {
      Section {
        PhoneDataBadge(model: model)
          .listRowBackground(Color.clear)
      }

      Section("场景预览") {
        CompanionScenePreview(
          characterID: selectedCharacterID,
          backgroundID: store.preferences.selectedBackgroundID
        )
        .listRowInsets(EdgeInsets())
        .accessibilityIdentifier("phone.companion-preview")
      }

      Section {
        ForEach(characters) { character in
          Button {
            store.selectCharacter(character.id)
          } label: {
            HStack(spacing: CompanionSpacing.medium) {
              Image("character_\(character.id)_idle_neutral_00")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 54, height: 58)
              VStack(alignment: .leading, spacing: 2) {
                Text(character.name)
                  .foregroundStyle(CompanionPalette.ink)
                Text(character.detail)
                  .font(.caption)
                  .foregroundStyle(CompanionPalette.secondaryText)
              }
              Spacer()
              if selectedCharacterID == character.id {
                Image(systemName: "checkmark")
                  .fontWeight(.semibold)
                  .foregroundStyle(CompanionPalette.mint)
              }
            }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("phone.character.\(character.id)")
        }
      } header: {
        Text("初始角色")
      } footer: {
        Text("当前主页显示一个角色；数据结构已为未来双角色位保留顺序。")
      }

      Section("共享背景") {
        ScrollView(.horizontal) {
          LazyHStack(spacing: CompanionSpacing.medium) {
            ForEach(backgrounds) { background in
              Button {
                store.selectBackground(background.id)
              } label: {
                ZStack(alignment: .topTrailing) {
                  Image("scene_\(background.id)_small")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFill()
                    .frame(width: 104, height: 128)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                  if store.preferences.selectedBackgroundID == background.id {
                    Image(systemName: "checkmark.circle.fill")
                      .symbolRenderingMode(.palette)
                      .foregroundStyle(.white, CompanionPalette.mint)
                      .padding(7)
                  }
                }
              }
              .buttonStyle(.plain)
              .accessibilityLabel(
                "\(background.name)\(store.preferences.selectedBackgroundID == background.id ? "，正在使用" : "")"
              )
              .accessibilityIdentifier("phone.background.\(background.id)")
            }
          }
          .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
      }

      Section {
        ForEach(items) { item in
          VStack(alignment: .leading, spacing: CompanionSpacing.small) {
            Button {
              store.previewOutfit(item.id)
            } label: {
              HStack(spacing: CompanionSpacing.medium) {
                Image(systemName: item.overlaySymbol ?? "pawprint.fill")
                  .font(.title3)
                  .foregroundStyle(item.color)
                  .frame(width: 32)
                Text(item.name)
                  .foregroundStyle(CompanionPalette.ink)
                Spacer()
                if equippedItemID == item.id {
                  Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(CompanionPalette.mint)
                } else if previewItemID == item.id {
                  Image(systemName: "eye.fill")
                    .foregroundStyle(CompanionPalette.blue)
                } else if !store.unlockedOutfitIDs.contains(item.id) {
                  Image(systemName: "lock.fill")
                    .foregroundStyle(CompanionPalette.secondaryText)
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
              "\(item.name)\(equippedItemID == item.id ? "，已装备" : "")\(store.unlockedOutfitIDs.contains(item.id) ? "" : "，未解锁")"
            )
            .accessibilityIdentifier("phone.wardrobe.preview.\(item.id)")

            if previewItemID == item.id {
              Text(
                previewItemID == equippedItemID
                  ? "当前已装备：\(previewedItem?.name ?? "基础外观")"
                  : "正在预览：\(previewedItem?.name ?? "基础外观")"
              )
              .font(.footnote)
              .foregroundStyle(CompanionPalette.secondaryText)
              .accessibilityIdentifier("phone.wardrobe-selection-state")

              if previewIsUnlocked {
                if previewItemID == equippedItemID {
                  Label("已装备", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(CompanionPalette.mint)
                    .accessibilityIdentifier("phone.wardrobe.equipped-status")
                } else {
                  Button {
                    store.equipPreviewedOutfit()
                  } label: {
                    Label("装备这件装扮", systemImage: "tshirt.fill")
                      .frame(maxWidth: .infinity)
                  }
                  .buttonStyle(.borderedProminent)
                  .tint(CompanionPalette.mint)
                  .disabled(store.isSavingPreferences)
                  .accessibilityIdentifier("phone.wardrobe.equip")
                }
              } else {
                Label("还未解锁；可以预览，但不能装备", systemImage: "lock.fill")
                  .font(.footnote.weight(.semibold))
                  .foregroundStyle(CompanionPalette.secondaryText)
                  .accessibilityIdentifier("phone.wardrobe.locked-reason")
              }
            }
          }
        }

        if equippedItemID != "default" {
          Button("恢复默认外观") {
            store.resetOutfit()
          }
          .disabled(store.isSavingPreferences)
          .accessibilityIdentifier("phone.wardrobe.reset")
        }
      } header: {
        Text("装扮")
      } footer: {
        if let status = store.statusMessage {
          Text(status)
            .accessibilityIdentifier("phone.wardrobe-sync-status")
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("伙伴与场景")
    .accessibilityIdentifier("phone.wardrobe")
  }
}

private struct CompanionScenePreview: View {
  let characterID: String
  let backgroundID: String

  var body: some View {
    ZStack(alignment: .bottom) {
      Image("scene_\(backgroundID)_large")
        .resizable()
        .interpolation(.none)
        .scaledToFill()
        .frame(maxWidth: .infinity)
        .aspectRatio(416 / 496, contentMode: .fit)
        .clipped()
      Image("character_\(characterID)_idle_neutral_00")
        .resizable()
        .interpolation(.none)
        .scaledToFit()
        .frame(width: 180, height: 196)
        .padding(.bottom, 30)
    }
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("角色与背景预览")
    .accessibilityValue("\(characterName)，\(backgroundName)")
  }

  private var characterName: String {
    characterID == "polar_bear" ? "白熊伙伴" : "企鹅伙伴"
  }

  private var backgroundName: String {
    switch backgroundID {
    case "spring_meadow_stream": "春日花溪"
    case "rainy_cabin_dusk": "雨夜木屋"
    case "moonlit_forest_camp": "月光森林营地"
    case "snow_birch_sunrise": "雪林日出"
    case "summer_lake": "夏日湖畔"
    case "rainy_reading_room": "雨日阅读室"
    case "aurora_observatory": "极光观星台"
    case "sunset_coast": "黄昏海岸"
    case "lantern_festival_square": "灯火节日广场"
    default: "冰海白昼"
    }
  }
}

private struct CompanionCharacterOption: Identifiable {
  let id: String
  let name: String
  let detail: String

  static let all = [
    CompanionCharacterOption(id: "penguin", name: "企鹅伙伴", detail: "黑发、蓝灰眼睛与企鹅装"),
    CompanionCharacterOption(id: "polar_bear", name: "白熊伙伴", detail: "灰发、琥珀眼睛与白熊装"),
  ]
}

private struct CompanionBackgroundOption: Identifiable {
  let id: String
  let name: String

  static let all = [
    CompanionBackgroundOption(id: "ice_ocean_day", name: "冰海白昼"),
    CompanionBackgroundOption(id: "spring_meadow_stream", name: "春日花溪"),
    CompanionBackgroundOption(id: "rainy_cabin_dusk", name: "雨夜木屋"),
    CompanionBackgroundOption(id: "moonlit_forest_camp", name: "月光森林营地"),
    CompanionBackgroundOption(id: "snow_birch_sunrise", name: "雪林日出"),
    CompanionBackgroundOption(id: "summer_lake", name: "夏日湖畔"),
    CompanionBackgroundOption(id: "rainy_reading_room", name: "雨日阅读室"),
    CompanionBackgroundOption(id: "aurora_observatory", name: "极光观星台"),
    CompanionBackgroundOption(id: "sunset_coast", name: "黄昏海岸"),
    CompanionBackgroundOption(id: "lantern_festival_square", name: "灯火节日广场"),
  ]
}

private struct WardrobeItem: Identifiable {
  let id: String
  let name: String
  let overlaySymbol: String?
  let color: Color

  static let samples = [
    WardrobeItem(
      id: "default", name: "基础外观", overlaySymbol: nil, color: CompanionPalette.mint),
    WardrobeItem(
      id: "soccer_scarf", name: "球场围巾", overlaySymbol: "wind",
      color: CompanionPalette.rose),
    WardrobeItem(
      id: "scarf", name: "冒险围巾", overlaySymbol: "wind", color: CompanionPalette.rose),
    WardrobeItem(
      id: "leaf", name: "发光叶子", overlaySymbol: "leaf.fill", color: CompanionPalette.mint),
    WardrobeItem(
      id: "star", name: "守夜星星", overlaySymbol: "star.fill", color: CompanionPalette.gold),
    WardrobeItem(
      id: "drop", name: "雨滴徽章", overlaySymbol: "drop.fill", color: CompanionPalette.blue),
  ]
}
